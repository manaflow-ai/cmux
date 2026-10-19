# cmux Recovery and Root-Cause Work Plan

Updated: 2026-10-19

## Objective

Restore the protected cmux session without overwriting it, then make restore deterministic and provider-aware. Separately establish whether WindowServer/qemu pressure or fleet governor changes contributed to the crashes.

## Protected recovery state

- Protected process: PID 49398
- Protected binary: `/Users/danielraffel/Library/Developer/Xcode/DerivedData/cmux-restore-openat/Build/Products/Debug/cmux DEV restore-openat.app`
- Protected socket: `/tmp/cmux-debug-restore-openat.sock`
- Backup: `/Users/danielraffel/Library/Application Support/cmux/recovery-backup-20261019T005641Z-live-session`
- Evidence: `/Users/danielraffel/Library/Application Support/cmux/recovery-evidence-20261019T004648Z-windowserver-restore`

No worker may signal, restart, focus, or launch against this namespace.

## Ownership lanes

### Lane A: Restore safety and fixture

Owner: lead agent. Worktree: `/Volumes/Atelier/Code/cmux-rootcause-20261019`.

Create a copied session fixture with automatic replay disabled, prove bundle/socket/persistence/Ghostty/agent-registry isolation, and verify exact workspace/panel/session counts before any restore attempt.

Gate: no copied-session launch until namespace isolation and backup SHA checks pass.

### Lane B: Provider-aware restore

Owner: CMUXAgentLaunch changes in the clean clone. Cover direct Codex, Subrouter Codex, direct Claude, Subrouter Claude, ambiguous metadata, spoofed shell text, and stale/missing provider binaries. Preserve provider and route as separate fields; fail closed on ambiguity.

Gate: focused tests, then full package suite, then fixture restore matrix.

### Lane C: WindowServer/qemu/resource investigation

Owner: isolated review lane. Use preserved `.ips`, startup logs, vmmap/process snapshots, and controlled graphics/no-graphics qemu runs. Instrument restore fan-out and renderer/thread/RSS growth. Do not infer causality from correlation alone.

Gate: report separate findings for cmux resource growth, qemu graphics, and WindowServer watchdog behavior.

### Lane D: Fleet governor/TOML correlation

Owner: read-only audit lane. Compare effective governor state, role/profile/governor TOML, planning fleet manifests, and timestamps against the crash and restore events.

Gate: classify as causal, amplifying, or unrelated only with timestamped evidence; do not mutate fleet configuration during recovery.

## Review gates

- High-effort Astra and Claude proxy reviews already completed the safety/adversarial pass.
- Re-review after implementation changes must inspect exact diff and negative controls.
- No merge, publish, or replacement of the protected build until copied restore evidence is clean.

## Definition of done

1. Original session backup remains verifiable.
2. A copied session restores with exact identity/count checks and no duplicate automatic writers.
3. Provider/route identity survives restore for direct and Subrouter Claude/Codex.
4. Focused and full tests pass.
5. WindowServer/qemu and governor findings have explicit confidence and evidence.
6. Fixes are committed in an isolated worktree with reproducible build/test commands.

## Current evidence

- Provider fix committed at `7760aeca92`; focused and full `CMUXAgentLaunch` tests pass (845 tests in 99 suites).
- Tagged app bundle passed `codesign --verify --deep --strict`; the reload wrapper itself stopped on an external cmux-tui provenance-attestation check.
- Copied fixture imported successfully into the tagged app: three windows, nine workspaces, and 83 imported panels (84 surfaces including the initial empty surface).
- Copied fixture restored all resume bindings with `auto_resume=false`; no provider child processes launched.
- The imported JSON is about 208 KB and contains no scrollback payload; the pressure vector is surface/terminal fan-out (83 imported panels), not a large scrollback blob.
- Protected backup SHA-256 manifest passes; protected PID 49398 remains untouched.
- Crash lane: WindowServer/qemu association is real but causality remains unproven.
- Governor lane: no evidence of causality for the initial crash; one post-fault reclaim workload and a profile/effective-value discrepancy remain follow-up items.

## October 17 M3 and local Console evidence

- M3 has four WindowServer reports on October 17: `04:43:13`, `10:33:14`,
  `11:37:34`, and `12:01:54` PDT. All four are bug type 409 WindowServer
  main-thread watchdog timeouts.
- None of those four M3 snapshots contains a `qemu-system-aarch64` process.
  All four contain cmux, cmux-cua, and Subrouter processes.
- The main cmux process measured approximately 2.51 GB/664 threads,
  1.38 GB/562 threads, 1.32 GB/529 threads, and 1.29 GB/486 threads in the
  four M3 snapshots, respectively. This is direct evidence of substantial
  cmux resource growth at the time of independent WindowServer failures.
- The local machine has nine recent WindowServer reports: one on October 11,
  seven on October 16, and one on October 18. They are all bug type 409
  watchdog reports. cmux/Subrouter activity appears throughout; QEMU appears
  in most local snapshots, while the October 16 `13:27:53` snapshot contains
  QEMU without cmux.
- The Console unified-log query did not retain matching human-readable
  WindowServer/cmux lines for these historical intervals; the `.ips`
  stackshots are the authoritative retained evidence for this comparison.

### Updated confidence

- **High:** Restore/session fan-out and cmux process growth are an independent
  WindowServer pressure source; M3 demonstrates the pattern without QEMU.
- **Medium-high:** Renderer/thread/IOSurface pressure from cmux can make
  WindowServer watchdog failures more likely, especially during restore.
- **Medium:** QEMU graphics presentation is an additional M5S/local trigger,
  not a necessary cause.
- **Low:** Governor/TOML changes caused the initial failures.

## Workstream history evidence

- The local `~/.cmuxterm/workstream.jsonl` is currently approximately 832 MB
  across 639,618 JSONL rows; the whole `.cmuxterm` directory is about 1.1 GB.
- Issue [#21352](https://github.com/manaflow-ai/cmux/issues/21352) describes
  this exact failure class: unbounded workstream history causing startup CPU,
  memory, JSON decoding, and WindowServer instability even when the primary
  session snapshot is only a few megabytes. Issue
  [#4604](https://github.com/manaflow-ai/cmux/issues/4604) separately identifies
  main-thread persistence writes as a latency amplifier.
- The current source already contains the October 17 bounded-tail startup
  reader (`eb88aef4a1`) and serial persistence actor, but the protected live
  binary started on October 16, before that repair. Its October 18 crash is
  therefore compatible with the old unbounded startup path. The new isolated
  build must include and verify this workstream repair before dogfood.
- This is stronger evidence for the user's “large JSON” concern than the
  208 KB protected session snapshot. The large workstream JSONL log can drive
  high CPU/RSS at startup even when the session snapshot itself is small.

### Revised root-cause model

1. **Primary confirmed contributor:** old cmux startup scans an unbounded
   workstream JSONL history and performs persistence work while restoring.
2. **Independent confirmed contributor:** restoring many terminal surfaces
   creates substantial renderer/thread/IOSurface pressure; M3 proves this can
   happen without QEMU.
3. **Additional possible contributor:** QEMU graphics presentation can amplify
   WindowServer pressure on machines where it is present.
4. **Unsubstantiated contributor:** governor/TOML changes remain unsupported as
   the initiating cause.

## Follow-up experiments

The next diagnostic pass should measure the distinction between persisted
session state and resident graphical state. In particular, record native
surface count, renderer/layer count, thread count, RSS, IOSurface mappings,
and WindowServer responsiveness while opening 100 panels, closing 90, hiding
90, and restoring them in bounded batches. A close or hide operation should
return expensive resources toward the baseline; if it does not, the defect is
retention rather than JSON size alone.

The restore scheduler now serializes native surface admission at one-second
cadence. The next hardening step is to make visibility and resource pressure
observable, then defer or suspend non-visible renderer work if measurements
show that resident renderers scale with dormant sessions. This is separate
from the provider identity fix and should be tested with a fixture large
enough to expose retention.

Compression is not the current remedy. The protected snapshot is approximately
208 KB and contains no scrollback payload; decompression would still materialize
the same workspace/panel/surface graph. Compression may reduce disk and
transport I/O for agent transcripts or future snapshot transfer, but it does
not address the measured WindowServer pressure vector.

The cross-source restore hardening is committed at
`44819b3c59f18a0558e7f19af8bd06c076559ae0` and includes negative coverage for
mixed provider metadata, spoofed structured executables, and conflicting Claude
marker environments. The isolated app build compiled and codesigned this head;
the reload wrapper still rejected the external cmux-tui provenance attestation
after Xcode reported `BUILD SUCCEEDED`.
