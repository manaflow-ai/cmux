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

The October 18 local WindowServer report is independently hashed as
`9b728ffedcff4b168330040f5a174b28742c941f956e32bb16db5ed31332b8f5`. It is
macOS 27.0.1 watchdog bug 409 with a 40-second WindowServer no-check-in;
that snapshot shows cmux at about 1.06 GB resident and QEMU at about 5.69 GB.
The paired QEMU report is hashed as
`83f09a5e5d65ee89bba302ef6f938044f1081a51028b88bd6b73752e3e099ee` and
aborts in `NSCGLSurface flushRect`/`CGLFlushDrawable` through gfxstream's
`eglSwapBuffers`. This is strong evidence for a QEMU graphics/WindowServer
interaction in that incident, but it does not establish that QEMU caused the
independent M3 watchdog reports where no QEMU process was present.

## M5S external OWC/NVMe comparison (2026-10-19T08:41Z)

The same 4 TB OWC Express 1M2 80G enclosure/PCIe APFS layout is healthy on
M3 but currently stalls on M5S. Both machines report APFS on `/dev/disk6s2`,
PCI-Express transport, solid-state media, and `SMART Status: Verified`; this
does not support a simple NAND/media failure diagnosis. M3's `Workshop`
volume accepts the existing write/fsync probe, while M5S's `Atelier` volume
fails a new `mktemp` write immediately with `Interrupted system call`.

The Thunderbolt identity and link are materially different: M5S reports OWC
firmware `64.1` and upstream micro-firmware `1.11.0`, at 80 Gb/s; M3 reports
firmware `61.61` and upstream micro-firmware `1.7.0`, also at 80 Gb/s. The
same SSD model and negotiated link speed with different bridge firmware makes
an OWC bridge/firmware/power/link interaction a stronger M5S-specific lead
than the SSD media itself. No SMART tool is installed on either host, so
`SMART Status: Verified` is the available health evidence, not a full NVMe
health-log dump.

Current storage confidence: **low** for NAND/media failure, **medium-high**
for an APFS/Thunderbolt/process-contention stall, and **medium** for a
bridge-firmware or power/link interaction. Re-test after stale agent/TartCI
process cleanup and a controlled sleep/wake or reboot; do not enable the M5S
runner pool until write, fsync, and `loop.pid` reads all pass.

The process census at the same time found many long-lived `cmux-cua serve`
helpers, a two-day `rescore_daily_until_2026-10-22.sh`, a TartCI
`disk_reclaim.py --fix`, and diagnostic processes actively attempting writes
and reads under `/Volumes/Atelier`. A recursive `lsof +D /Volumes/Atelier`
itself did not return within 30 seconds. These are plausible amplifiers of an
already-stalled volume and explain why the host can remain SSH-reachable while
the CI volume is unusable. They are not proof that any one helper caused the
stall; cleanup must be scoped to confirmed stale jobs and must not terminate
the protected cmux process.

The fleet correlation is also timestamped. Around the local crash
(`2026-10-18T23:39:41Z`), TartCI reported the Atelier store stalled since
`19:07:10Z`, with VM-store/Tart/worktree listings exceeding 15 seconds and a
suspected system-wide sandbox/TCC stall. The same watchdog cycle reported a
stuck reclaim operation, a partially unreadable gate-demand query, and stale
M3 Wi-Fi reachability. Current governor resolution is 30 cores/256 GB with 26
lease-capacity cores, 20 reserved for gates, and 6 effective background cores;
the TOML request for 12 background cores is clamped to 6. There are no active
leases now. This makes the storage/TCC stall a first-class coincident failure
condition, while the governor/TOML discrepancy remains an amplifier or
operational concern rather than a proven WindowServer cause.

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

## Exact-head validation update (2026-10-19)

The current repair branch is
[`4cc404c865d30137f76eba86f2d89c7ec9e5e371`](https://github.com/danielraffel/cmux/commit/4cc404c865d30137f76eba86f2d89c7ec9e5e371).
It includes the CLI `cmux feed clear` revision-floor fix and its regression
test. The CMUXAgentLaunch package passes **883 tests in 100 suites**, including
the focused persistence/startup set (31 tests in 2 suites); Swift parse checks
for the changed CLI and persistence source pass. Astra and an independent
Claude Opus review both found no blocking defect in the exact repair slice.

Native `cmuxTests/FeedCoordinatorTests` and a fresh full app-target build are
still outstanding. The app build previously stopped while `/Volumes/Atelier`
was stalling, so those are validation gaps rather than green claims. The
protected PID, socket, live JSONL, and backup were not touched during this
repair or review.
