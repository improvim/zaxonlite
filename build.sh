#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="zaxonlite-build"
PKG_CACHE_VOL="zaxonlite-zig-pkgs"   # named volume: global zig package cache (persists across builds)
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"  # override with: ZIG_VERSION=0.16.1 ./build.sh --docker

DOCKER_OUT="${SCRIPT_DIR}/dist/docker"
LOCAL_OUT="${SCRIPT_DIR}/dist/local"

# Map host arch to Zig's download naming
case "$(uname -m)" in
  arm64|aarch64) ZIG_ARCH="aarch64" ;;
  x86_64)        ZIG_ARCH="x86_64" ;;
  *)
    echo "build.sh: unsupported host arch: $(uname -m)" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") <flag>

Build flags:
  --docker               Build inside Docker (Ubuntu 24.04 + Zig 0.16) → dist/docker/
  --local                Build with local toolchain (zig must be on PATH) → dist/local/
  --all                  Build both --docker and --local

Clean flags:
  --clean-binary-docker  Remove dist/docker/
  --clean-binary-local   Remove dist/local/ and zig-out/
  --purge-docker         Remove Docker image and zig package cache volume
  --clean                All clean methods above (including .zig-cache/)

  --help                 Show this message

Notes:
  - --docker builds a Linux AArch64/x86_64 ELF suited for the QASan pipeline.
  - --local builds for the host OS/arch (macOS → Mach-O; use inside Linux for a Linux ELF).
  - The Docker image is built once and reused; .zig-cache/ and the package cache volume
    persist between builds for incremental speed. Code changes are always picked up via
    the bind mount.
  - Add dist/ to .gitignore if you haven't already.
EOF
}

# ---------------------------------------------------------------------------

ensure_docker_image() {
  if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "[build.sh] Building Docker image (first run only)…"
    docker build \
      --build-arg "ZIG_ARCH=${ZIG_ARCH}" \
      --build-arg "ZIG_VERSION=${ZIG_VERSION}" \
      -t "$IMAGE" \
      -f "${SCRIPT_DIR}/Dockerfile.build" \
      "$SCRIPT_DIR"
  fi
}

build_docker() {
  ensure_docker_image
  mkdir -p "$DOCKER_OUT"
  echo "[build.sh] --docker: building zaxonlite → ${DOCKER_OUT}"
  docker run --rm \
    -v "${SCRIPT_DIR}:/src" \
    -v "${PKG_CACHE_VOL}:/root/.cache/zig" \
    -v "${DOCKER_OUT}:/out" \
    --workdir /src \
    "$IMAGE" \
    zig build -p /out
  echo "[build.sh] --docker: done."
  echo "[build.sh]   binary:  ${DOCKER_OUT}/bin/zaxon"
  echo "[build.sh]   library: ${DOCKER_OUT}/lib/libzaxonlite.a"
}

build_local() {
  mkdir -p "$LOCAL_OUT"
  echo "[build.sh] --local: building zaxonlite → ${LOCAL_OUT}"
  (cd "$SCRIPT_DIR" && zig build -p "$LOCAL_OUT")
  echo "[build.sh] --local: done."
  echo "[build.sh]   binary:  ${LOCAL_OUT}/bin/zaxon"
  echo "[build.sh]   library: ${LOCAL_OUT}/lib/libzaxonlite.a"
}

# ---------------------------------------------------------------------------

clean_binary_docker() {
  echo "[build.sh] --clean-binary-docker: removing ${DOCKER_OUT}"
  rm -rf "$DOCKER_OUT"
  echo "[build.sh]   done."
}

clean_binary_local() {
  echo "[build.sh] --clean-binary-local: removing ${LOCAL_OUT} and zig-out/"
  rm -rf "$LOCAL_OUT" "${SCRIPT_DIR}/zig-out"
  echo "[build.sh]   done."
}

purge_docker() {
  echo "[build.sh] --purge-docker: removing image ${IMAGE}"
  if docker image inspect "$IMAGE" > /dev/null 2>&1; then
    docker rmi "$IMAGE"
    echo "[build.sh]   image removed."
  else
    echo "[build.sh]   image not found, skipping."
  fi

  echo "[build.sh] --purge-docker: removing zig package cache volume ${PKG_CACHE_VOL}"
  if docker volume inspect "$PKG_CACHE_VOL" > /dev/null 2>&1; then
    docker volume rm "$PKG_CACHE_VOL"
    echo "[build.sh]   volume removed."
  else
    echo "[build.sh]   volume not found, skipping."
  fi
}

clean_all() {
  clean_binary_docker
  clean_binary_local
  purge_docker
  echo "[build.sh] --clean: removing .zig-cache/"
  rm -rf "${SCRIPT_DIR}/.zig-cache"
  echo "[build.sh] --clean: done."
}

# ---------------------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

case "$1" in
  --docker)              build_docker ;;
  --local)               build_local ;;
  --all)                 build_docker; build_local ;;
  --clean-binary-docker) clean_binary_docker ;;
  --clean-binary-local)  clean_binary_local ;;
  --purge-docker)        purge_docker ;;
  --clean)               clean_all ;;
  --help|-h)             usage ;;
  *)
    echo "build.sh: unknown flag: $1" >&2
    echo "" >&2
    usage >&2
    exit 1
    ;;
esac
