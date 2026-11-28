# Task-local cache portability experiment

These untracked scripts generate **commands for review**, never submit/upload themselves.
No production cache write, trusted GitHub environment, full source pack, or real device is involved.

Worker subprocesses inherit the outer fleet process group. Timeout and SIGTERM cleanup embeds the exact
production `measure.stop_tree` implementation; generated config records both its function-source digest
and its owning measure.py digest. Receipts preserve the original timeout/cancellation status, actual
child exit, and any cleanup error. The focused sleeping-descendant regression is recorded in
`timeout-test-results.log`.

The source receipt is `.default-speed-tools/sparse-study-status.json`, a completed controller snapshot:

- Study job: `31b28e964edd34f5a16dc5ae`, terminal `failed` before the native build.
- Source: `19834f1bd501f32e380edd7109422ab3d7206b21`.
- Workspace/input scope: `lane-test-manaflow-ai-cmux-19834f1bd501-cbfcc3c6`.
- Sparse source input: `src.000=sha256:3f73ad437c30cedc1aca8a3a0eba2176797eda2c3fc69a6a2fed3feb9b7a1f4b`.

The runner derives the sparse patterns and SHA from that job's command and reuses its input digest.
It cannot claim the later cache-fix commit was tested: a different source needs its own existing
supported sparse input receipt. The producer does execute the actual strip utility with the exact
production workspace-name list and `--keep ghostty-vt-sys`, followed by the actual source-mtime utility.

## Generate and inspect (no network)

From the checkout root:

```bash
python3 .default-speed-tools/portability/test_runner.py
python3 -m py_compile .default-speed-tools/portability/{runner,worker}.py
python3 .default-speed-tools/portability/runner.py producer \
  --study-status .default-speed-tools/sparse-study-status.json \
  --sha 19834f1bd501f32e380edd7109422ab3d7206b21 \
  --root /tmp/cmux-cache-portability-19834f1b-phone-default-speed-01 \
  --output .default-speed-tools/portability/producer-reviewed
bash -n .default-speed-tools/portability/producer-reviewed/producer.sh
bash -n .default-speed-tools/portability/producer-reviewed/commands.sh
```

The old-head `producer-reviewed` draft is already generated for inspection only. Do not dispatch it as evidence for `e2e5d1978520074bd0d568ac1751ffd2a92590a0`: generate a new directory using that head and its new completed study-status receipt.

Generation refuses an existing output directory. The worker refuses an existing private root, and removes
only the root it created. Each job independently reconstructs source at the identical absolute path and
uses `src/cmux-tui/target`; it cannot accidentally use the shared fleet target. Commands use the installed
fleet client directly, as `lane_fleet_test.py` does. Input reads retain the original lane's private scope.

## Only after review: managed producer and transfer

```bash
bash .default-speed-tools/portability/producer-reviewed/commands.sh
# Read the job ID from producer-reviewed/submit-receipt.json. One background condition wait:
bash /home/cmux/.local/share/cmux-fleet-client/current/ci.sh wait PRODUCER_JOB --timeout 3900
bash /home/cmux/.local/share/cmux-fleet-client/current/ci.sh artifact PRODUCER_JOB producer-artifact.tgz
mkdir producer-receipts
tar -xzf producer-artifact.tgz -C producer-receipts
python3 .default-speed-tools/portability/runner.py consumer \
  --producer-config .default-speed-tools/portability/producer-reviewed/config.json \
  --producer-directory producer-receipts \
  --output .default-speed-tools/portability/consumer-final
bash -n .default-speed-tools/portability/consumer-final/consumer.sh
```

Review `producer-receipts/exit.json`, `identity.json`, `timings.json`, `pruned-files.json`, and
`cache-manifest.json` before executing `consumer-final/commands.sh`. That command uploads each verified
cache part (at most 400 MiB, SHA checked again by the fleet client) to the same private lane, then submits
the consumer. Wait once in the background and download its artifact using the same commands with the
consumer job ID; `accepted.json` is the positive result. For failed jobs use the client's `artifact --failed`
option; `exit.json` and step logs retain failure, signal, timeout and actual child exit status.

## Acceptance and limits

- Producer uses a fresh target, proves real pruning removed workspace files without changing native
  hashes, records source mtimes **after** pruning, then archives with R2's `tar | zstd -T0 -3` operation.
- Consumer verifies source/tool/environment identity, chunk/archive/manifest digests, and native hashes
  after the real mtime restore. Its **first build** must complete in 60 seconds, print
  `Fresh ghostty-vt-sys`, never compile/run that native build script, and leave native hashes unchanged.
- Cargo, rustc and rustdoc are real binaries under the exact toolchain from rust-toolchain.toml.
  No rustup executable/proxy/install runs. The image must already have that complete Rust toolchain; missing Rust tools fail before the native build. Zig uses the owning `install-zig-ci.sh` in forced local mode, including the reviewed standard-library patch, then gets a stable task-private `tools/zig-tree` path. It never modifies `/opt`. Zig must match the gitlink's minimum version and the source helper's patched `Threaded.zig` hash; executable and full standard-library hashes must match between jobs. Compiler/linker/libc identity is recorded.
- The study target cannot be adopted: its absolute source is job-specific, its target includes a PID,
  and it did not export a cache manifest/archive. A separate cold producer is required. This experiment
  reuses its uploaded source pack, not its partial target.
- Setup, checkout, archive/restore and first-build wall/user/system costs are separate receipts.
  `overall.json` covers the worker before cleanup/artifact packaging, including Python hashing CPU.
- A successful consumer proves artifact portability on these recorded worker environments, **not** actual
  R2 publication/key selection, any source head other than the exact selected receipt, a device calibration, or the whole hourly gate.
- No worker has been dispatched by generating or testing these files.
