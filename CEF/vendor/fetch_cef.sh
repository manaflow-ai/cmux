#!/usr/bin/env bash
#
# fetch_cef.sh — fetch, verify, extract, and build the CEF binary distribution
# pinned by cef.lock.json. Idempotent.
#
# Designed to be safe under:
#   * incremental Xcode builds — exits fast when artefacts are already in place
#   * CI parallelism — per-tag cache, atomic rename on extract
#   * offline mode — if the tarball is already in the cache, no network
#
# Usage:
#   vendor/fetch_cef.sh                    # default: build wrapper, place under default DEST
#   vendor/fetch_cef.sh --dest <path>      # override DEST (where CEF lives for the build)
#   vendor/fetch_cef.sh --no-build         # download + extract only, skip cmake wrapper build
#   vendor/fetch_cef.sh --verify           # verify the lockfile hash against the cached tarball
#   vendor/fetch_cef.sh --print-paths      # print the resolved DEST and CEF version; exit 0
#
# Exit codes:
#   0   success
#   2   lockfile parse / arg error
#   3   SHA1 mismatch (lockfile or downloaded artefact)
#   4   network error and no cache fallback
#   5   wrapper build failed
#
# Environment variables:
#   CEF_VENDOR_CACHE   override the cache dir (default: ~/Library/Caches/cmux-cef-vendor)
#   CEF_VENDOR_DEST    where the extracted CEF dir + Frameworks/ output live
#                      (default: <script dir>/../upstream/CEFWebView/CEF and Frameworks)
#   CEF_VENDOR_MIRROR  optional internal mirror base URL (e.g. R2/S3). Tried before
#                      the public CDN.
#
# Outputs (in DEST):
#   CEF/<extracted_dir_name>/                     full CEF distribution
#   Frameworks/Chromium Embedded Framework.framework  versioned, ad-hoc sig stripped
#   Frameworks/libcef_dll_wrapper.a               static wrapper
#   Frameworks/include/                           C++ headers
#
# This script is the single source of truth for "where does CEF come from."
# Do not duplicate the URL / SHA1 anywhere else; read cef.lock.json instead.

set -euo pipefail

# ─── Paths & defaults ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKFILE="${SCRIPT_DIR}/cef.lock.json"

if [[ ! -f "${LOCKFILE}" ]]; then
  echo "fetch_cef: lockfile not found at ${LOCKFILE}" >&2
  exit 2
fi

CEF_VENDOR_CACHE="${CEF_VENDOR_CACHE:-${HOME}/Library/Caches/cmux-cef-vendor}"
# Default DEST = parent of vendor/ (the `cef/` package root inside cmux).
# Produces cef/CEF/<extracted>/ and cef/Frameworks/<artefacts>.
DEFAULT_DEST="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || true)"
DEST="${CEF_VENDOR_DEST:-${DEFAULT_DEST}}"

DO_BUILD=1
DO_VERIFY_ONLY=0
DO_PRINT_PATHS=0

while (( $# > 0 )); do
  case "$1" in
    --dest)
      shift
      DEST="$1"
      ;;
    --no-build)
      DO_BUILD=0
      ;;
    --verify)
      DO_VERIFY_ONLY=1
      ;;
    --print-paths)
      DO_PRINT_PATHS=1
      ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *)
      echo "fetch_cef: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "${DEST}" ]]; then
  echo "fetch_cef: could not resolve DEST. Pass --dest <path> or set CEF_VENDOR_DEST." >&2
  exit 2
fi

# ─── Lockfile parsing (python3 to avoid jq dependency) ───────────────────────

read_lock() {
  python3 - "$LOCKFILE" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    lock = json.load(f)
key = sys.argv[2]
node = lock
for part in key.split('.'):
    if part.endswith(']'):
        name, idx = part[:-1].split('[')
        node = node[name][int(idx)]
    else:
        node = node[part]
print(node)
PY
}

CEF_VERSION="$(read_lock version)"
TARBALL_NAME="$(read_lock platforms.macosarm64.tarball)"
TARBALL_SHA1="$(read_lock platforms.macosarm64.sha1)"
TARBALL_SIZE="$(read_lock platforms.macosarm64.size_bytes)"
EXTRACTED_NAME="$(read_lock platforms.macosarm64.extracted_dir_name)"
PUBLIC_BASE_URL="$(read_lock sources[0].base_url)"

if [[ "${DO_PRINT_PATHS}" == "1" ]]; then
  printf 'CEF_VERSION=%s\nDEST=%s\nCACHE=%s\nTARBALL=%s\nEXTRACTED=%s\n' \
    "${CEF_VERSION}" "${DEST}" "${CEF_VENDOR_CACHE}" \
    "${TARBALL_NAME}" "${EXTRACTED_NAME}"
  exit 0
fi

# ─── SHA1 helpers ────────────────────────────────────────────────────────────

sha1_of() {
  shasum -a 1 "$1" | awk '{print $1}'
}

verify_tarball() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    return 1
  fi
  local actual_size actual_sha1
  actual_size=$(stat -f%z "${path}")
  if [[ "${actual_size}" != "${TARBALL_SIZE}" ]]; then
    echo "fetch_cef: cached tarball size mismatch (got ${actual_size}, want ${TARBALL_SIZE})" >&2
    return 1
  fi
  actual_sha1=$(sha1_of "${path}")
  if [[ "${actual_sha1}" != "${TARBALL_SHA1}" ]]; then
    echo "fetch_cef: cached tarball SHA1 mismatch" >&2
    echo "  got:  ${actual_sha1}" >&2
    echo "  want: ${TARBALL_SHA1}" >&2
    return 1
  fi
  return 0
}

# ─── Download with mirror fallback ───────────────────────────────────────────

download() {
  local url="$1"
  local out="$2"
  local tmp="${out}.partial.$$"
  echo "fetch_cef: downloading ${url}"
  if curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "${tmp}" "${url}"; then
    mv -f "${tmp}" "${out}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

ensure_tarball() {
  mkdir -p "${CEF_VENDOR_CACHE}/${CEF_VERSION}"
  local tarball_path="${CEF_VENDOR_CACHE}/${CEF_VERSION}/${TARBALL_NAME}"

  if verify_tarball "${tarball_path}"; then
    # Log to stderr so the caller's $() capture only sees the path.
    echo "fetch_cef: cached tarball at ${tarball_path} (sha1 OK)" >&2
    printf '%s' "${tarball_path}"
    return 0
  fi

  # Try mirror first if configured.
  if [[ -n "${CEF_VENDOR_MIRROR:-}" ]]; then
    local mirror_url="${CEF_VENDOR_MIRROR%/}/${CEF_VERSION}/${TARBALL_NAME}"
    if download "${mirror_url}" "${tarball_path}"; then
      if verify_tarball "${tarball_path}"; then
        printf '%s' "${tarball_path}"
        return 0
      else
        echo "fetch_cef: mirror artefact failed verification, falling back to public CDN" >&2
        rm -f "${tarball_path}"
      fi
    fi
  fi

  # Public CDN. URL needs `+` percent-encoded to %2B.
  local url_path
  url_path=$(printf '%s' "${TARBALL_NAME}" | python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))')
  local public_url="${PUBLIC_BASE_URL%/}/${url_path}"
  if ! download "${public_url}" "${tarball_path}"; then
    echo "fetch_cef: download from ${public_url} failed" >&2
    return 4
  fi
  if ! verify_tarball "${tarball_path}"; then
    rm -f "${tarball_path}"
    return 3
  fi
  printf '%s' "${tarball_path}"
}

# ─── Extract ─────────────────────────────────────────────────────────────────

ensure_extracted() {
  local tarball_path="$1"
  local out_root="${DEST}/CEF"
  local out_dir="${out_root}/${EXTRACTED_NAME}"

  if [[ -d "${out_dir}" && -f "${out_dir}/Release/Chromium Embedded Framework.framework/Versions/Resources/Info.plist" ]] \
    || [[ -d "${out_dir}/Release" && -d "${out_dir}/libcef_dll" ]]; then
    echo "fetch_cef: CEF already extracted at ${out_dir}"
    return 0
  fi

  mkdir -p "${out_root}"
  local tmp_root
  tmp_root=$(mktemp -d "${out_root}/.extract-XXXXXX")
  echo "fetch_cef: extracting into ${tmp_root}"
  tar -xjf "${tarball_path}" -C "${tmp_root}"

  local staged="${tmp_root}/${EXTRACTED_NAME}"
  if [[ ! -d "${staged}" ]]; then
    echo "fetch_cef: expected ${EXTRACTED_NAME} inside tarball, not found" >&2
    rm -rf "${tmp_root}"
    return 3
  fi

  rm -rf "${out_dir}"
  mv "${staged}" "${out_dir}"
  rm -rf "${tmp_root}"
  echo "fetch_cef: extracted to ${out_dir}"
}

# ─── Build C++ wrapper + populate Frameworks/ ────────────────────────────────

build_wrapper_and_install() {
  local cef_dir="${DEST}/CEF/${EXTRACTED_NAME}"
  local frameworks_dir="${DEST}/Frameworks"
  local fw_name="Chromium Embedded Framework"
  local wrapper_static="${cef_dir}/libcef_dll_wrapper/Release/libcef_dll_wrapper.a"

  if [[ ! -f "${wrapper_static}" ]]; then
    echo "fetch_cef: building C++ wrapper at ${cef_dir}"
    (
      cd "${cef_dir}"
      cmake -G "Xcode" -DPROJECT_ARCH="arm64" . >/dev/null
      xcodebuild -configuration Release -target libcef_dll_wrapper >/dev/null
    ) || {
      echo "fetch_cef: wrapper build failed" >&2
      return 5
    }
  fi

  mkdir -p "${frameworks_dir}/include"
  cp -f "${wrapper_static}" "${frameworks_dir}/"
  rsync -a --delete "${cef_dir}/include/" "${frameworks_dir}/include/"

  rm -rf "${frameworks_dir}/${fw_name}.framework"
  cp -R "${cef_dir}/Release/${fw_name}.framework" "${frameworks_dir}/"
  restructure_framework "${frameworks_dir}/${fw_name}.framework"
}

# Restructures CEF's flat .framework into the versioned macOS layout that
# Xcode code signing requires, then updates the install id to @rpath.
restructure_framework() {
  local fw="$1"
  local fw_name
  fw_name=$(basename "${fw}" .framework)

  if [[ -d "${fw}/Versions/A" ]]; then
    # Already restructured.
    install_name_tool -id "@rpath/${fw_name}.framework/Versions/A/${fw_name}" \
      "${fw}/Versions/A/${fw_name}"
    return 0
  fi

  mkdir -p "${fw}/Versions/A"
  mv "${fw}/${fw_name}" "${fw}/Versions/A/"
  if [[ -d "${fw}/Resources" ]]; then
    mv "${fw}/Resources" "${fw}/Versions/A/"
  fi
  if [[ -d "${fw}/Libraries" ]]; then
    mv "${fw}/Libraries" "${fw}/Versions/A/"
  fi
  ln -sfn "A" "${fw}/Versions/Current"
  ln -sfn "Versions/Current/${fw_name}" "${fw}/${fw_name}"
  ln -sfn "Versions/Current/Resources" "${fw}/Resources"
  if [[ -d "${fw}/Versions/A/Libraries" ]]; then
    ln -sfn "Versions/Current/Libraries" "${fw}/Libraries"
  fi

  install_name_tool -id "@rpath/${fw_name}.framework/Versions/A/${fw_name}" \
    "${fw}/Versions/A/${fw_name}"

  # Strip CEF's pre-existing ad-hoc signature (which embeds the upstream
  # team id) and re-sign ad-hoc with a clean code directory. The cmux
  # release build will codesign --force on top of this with the cmux
  # Developer ID; for dev / package tests, ad-hoc keeps dyld happy under
  # hardened runtime library validation.
  codesign --remove-signature "${fw}/Versions/A/${fw_name}" 2>/dev/null || true
  codesign --force --sign - --timestamp=none "${fw}/Versions/A/${fw_name}" >/dev/null 2>&1 \
    || echo "fetch_cef: ad-hoc re-sign of framework failed; release build will need to re-sign" >&2
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "fetch_cef: version=${CEF_VERSION} dest=${DEST}"

if [[ "${DO_VERIFY_ONLY}" == "1" ]]; then
  tarball_path="${CEF_VENDOR_CACHE}/${CEF_VERSION}/${TARBALL_NAME}"
  if verify_tarball "${tarball_path}"; then
    echo "fetch_cef: verify OK"
    exit 0
  fi
  echo "fetch_cef: verify FAILED" >&2
  exit 3
fi

tarball_path=$(ensure_tarball)
ensure_extracted "${tarball_path}"

if [[ "${DO_BUILD}" == "1" ]]; then
  build_wrapper_and_install
  echo "fetch_cef: Frameworks/ populated at ${DEST}/Frameworks"
fi

echo "fetch_cef: done"
