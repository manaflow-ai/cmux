#!/usr/bin/env bash

set -euo pipefail

if (( $# != 1 )); then
  echo "usage: verify_release_registry_authority.sh crates|npm|pypi" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

case "$1" in
  crates)
    python3 "$script_dir/verify_crates_ownership.py" \
      --package cmux-sdk \
      --package cmux-sidebar \
      --repository https://github.com/manaflow-ai/cmux \
      --owner-id 431397 \
      --owner-login lawrencecchen
    ;;
  npm)
    python3 "$script_dir/verify_npm_provenance.py" \
      --package cmux-sdk \
      --version 0.0.0-bootstrap.0 \
      --repository-url git+https://github.com/manaflow-ai/cmux.git \
      --repository-directory cmux-tui/bindings/typescript \
      --owner lawrencechen \
      --workflow .github/workflows/sdk-bootstrap-npm.yml \
      --workflow-ref refs/heads/main \
      --dist-tag bootstrap \
      --publisher owner
    ;;
  pypi)
    python3 "$script_dir/verify_pypi_provenance.py" \
      --package cmux-sdk \
      --version 0.0.0a0 \
      --filename cmux_sdk-0.0.0a0-py3-none-any.whl \
      --filename cmux_sdk-0.0.0a0.tar.gz \
      --repository https://github.com/manaflow-ai/cmux \
      --owner lawrencecchen \
      --workflow sdk-bootstrap-pypi.yml \
      --environment pypi-bootstrap \
      --authority-only
    ;;
  *)
    echo "usage: verify_release_registry_authority.sh crates|npm|pypi" >&2
    exit 2
    ;;
esac
