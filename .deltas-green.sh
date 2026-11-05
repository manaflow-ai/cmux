#!/usr/bin/env bash
python3 -m pip install -q pyyaml pytest >/dev/null 2>&1 || true
rc=0
for t in tests/test_nightly_deltas_sparse_checkout.py tests/test_ci_checkout_lean.py tests/test_nightly_owned_minis_only.py tests/test_nightly_cmux_tui_resolve.py tests/test_nightly_delivery_concurrency.py tests/test_publish_app_token_workflow.py tests/test_nightly_next_artifact_check.py tests/test_nightly_promotion_admission.py tests/test_nightly_one_mini.py tests/test_nightly_signing_on_cmux15.py tests/test_workflow_file_size.py tests/test_generate_nightly_deltas.sh; do
  [ -f "$t" ] || continue
  case "$t" in *.sh) bash "$t" >/tmp/o 2>&1 ;; *) python3 "$t" >/tmp/o 2>&1 ;; esac
  r=$?; echo "== $t rc=$r"; [ $r -ne 0 ] && { tail -25 /tmp/o; rc=1; }
done
exit $rc
