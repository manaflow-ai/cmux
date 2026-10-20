#!/usr/bin/env bash

set -euo pipefail

if (( $# != 2 )); then
  echo "usage: verify_release_registry_state.sh VERSION EXPECTED_COMMIT" >&2
  exit 2
fi

version="$1"
expected_commit="$2"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "release registry version must match X.Y.Z" >&2
  exit 2
fi
if [[ ! "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "release registry commit must be a full lowercase Git SHA" >&2
  exit 2
fi

shopt -s nullglob
npm_packages=(validated-npm/*.tgz)
python_wheels=(validated-python/*.whl)
python_sdists=(validated-python/*.tar.gz)
[[ "${#npm_packages[@]}" == 1 ]] || {
  echo "expected one validated npm artifact, found ${#npm_packages[@]}" >&2
  exit 1
}
[[ "${#python_wheels[@]}" == 1 ]] || {
  echo "expected one validated Python wheel, found ${#python_wheels[@]}" >&2
  exit 1
}
[[ "${#python_sdists[@]}" == 1 ]] || {
  echo "expected one validated Python source distribution, found ${#python_sdists[@]}" >&2
  exit 1
}

registry_state="$(mktemp)"
trap 'rm -f "$registry_state"' EXIT

python3 cmux-tui/bindings/reconcile_registry_artifact.py check \
  --registry crates \
  --package cmux-sdk \
  --version "$version" \
  --artifact "validated-rust-sdk/cmux-sdk-$version.crate"
sleep 1
python3 cmux-tui/bindings/reconcile_registry_artifact.py check \
  --registry crates \
  --package cmux-sidebar \
  --version "$version" \
  --artifact "validated-sidebar/cmux-sidebar-$version.crate"
GITHUB_OUTPUT="$registry_state" \
  python3 cmux-tui/bindings/reconcile_registry_artifact.py check \
    --registry npm \
    --package cmux-sdk \
    --version "$version" \
    --artifact "${npm_packages[0]}" \
    --write-github-output \
    --github-output-name npm
GITHUB_OUTPUT="$registry_state" \
  python3 cmux-tui/bindings/reconcile_registry_artifact.py check \
    --registry pypi \
    --package cmux-sdk \
    --version "$version" \
    --artifact "${python_wheels[0]}" \
    --allowed-artifact "${python_wheels[0]}" \
    --allowed-artifact "${python_sdists[0]}" \
    --write-github-output \
    --github-output-name python_wheel
GITHUB_OUTPUT="$registry_state" \
  python3 cmux-tui/bindings/reconcile_registry_artifact.py check \
    --registry pypi \
    --package cmux-sdk \
    --version "$version" \
    --artifact "${python_sdists[0]}" \
    --allowed-artifact "${python_wheels[0]}" \
    --allowed-artifact "${python_sdists[0]}" \
    --write-github-output \
    --github-output-name python_sdist

read_registry_state() {
  local name="$1"
  local matches=()
  mapfile -t matches < <(
    grep -E "^${name}=(match|missing)$" "$registry_state" || true
  )
  if (( ${#matches[@]} != 1 )); then
    echo "registry check did not produce one $name state" >&2
    exit 1
  fi
  printf '%s\n' "${matches[0]#*=}"
}

npm_status="$(read_registry_state npm)"
python_wheel_status="$(read_registry_state python_wheel)"
python_sdist_status="$(read_registry_state python_sdist)"

sleep 1
python3 cmux-tui/bindings/verify_crates_ownership.py \
  --package cmux-sdk \
  --package cmux-sidebar \
  --repository https://github.com/manaflow-ai/cmux \
  --owner-id 431397 \
  --owner-login lawrencecchen

python3 cmux-tui/bindings/verify_npm_provenance.py \
  --package cmux-sdk \
  --version 0.0.0-bootstrap.0 \
  --repository-url git+https://github.com/manaflow-ai/cmux.git \
  --repository-directory cmux-tui/bindings/typescript \
  --owner lawrencechen \
  --workflow .github/workflows/sdk-bootstrap-npm.yml \
  --workflow-ref refs/heads/main \
  --dist-tag bootstrap \
  --publisher owner

python3 cmux-tui/bindings/verify_pypi_provenance.py \
  --package cmux-sdk \
  --version 0.0.0a0 \
  --filename cmux_sdk-0.0.0a0-py3-none-any.whl \
  --filename cmux_sdk-0.0.0a0.tar.gz \
  --repository https://github.com/manaflow-ai/cmux \
  --owner lawrencecchen \
  --workflow sdk-bootstrap-pypi.yml \
  --environment pypi-bootstrap

if [[ "$npm_status" == "match" ]]; then
  python3 cmux-tui/bindings/verify_npm_provenance.py \
    --package cmux-sdk \
    --version "$version" \
    --repository-url git+https://github.com/manaflow-ai/cmux.git \
    --repository-directory cmux-tui/bindings/typescript \
    --artifact "${npm_packages[0]}" \
    --owner lawrencechen \
    --workflow .github/workflows/sdk-release-cut.yml \
    --workflow-ref refs/heads/main \
    --expected-commit "$expected_commit" \
    --dist-tag latest \
    --publisher github-actions
fi

python_filenames=()
if [[ "$python_wheel_status" == "match" ]]; then
  python_filenames+=(--filename "$(basename "${python_wheels[0]}")")
fi
if [[ "$python_sdist_status" == "match" ]]; then
  python_filenames+=(--filename "$(basename "${python_sdists[0]}")")
fi
if (( ${#python_filenames[@]} > 0 )); then
  python3 cmux-tui/bindings/verify_pypi_provenance.py \
    --package cmux-sdk \
    --version "$version" \
    --repository https://github.com/manaflow-ai/cmux \
    --owner lawrencecchen \
    --workflow sdk-release-cut.yml \
    --environment pypi \
    --expected-commit "$expected_commit" \
    --expected-ref refs/heads/main \
    "${python_filenames[@]}"
fi

echo "verified current SDK registry state for $version at $expected_commit"
