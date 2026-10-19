# cmux Recovery and Root-Cause Work Plan

Updated: 2026-10-19

## Objective

Restore the protected cmux session without overwriting it, then make restore deterministic and provider-aware. Separately establish whether WindowServer/qemu pressure or fleet governor changes contributed to the crashes.

## Protected recovery state

- Protected process: PID 49398
- Protected binary: `/Users/danielraffel/Library/Developer/Xcode/DerivedData/cmux-restore-openat/Build/Products/Debug/cmux DEV restore-openat.app`
- Protected socket: `/tmp/cmux-debug-restore-openat.sock`
- Latest JSONL backup: `/Users/danielraffel/.cmuxterm/backups/workstream-20261019T083000Z.jsonl`
- Latest backup sidecar: `/Users/danielraffel/.cmuxterm/backups/workstream-20261019T083000Z.jsonl.sha256`
- Recovery evidence bundle: `/Users/danielraffel/Library/Application Support/cmux/recovery-evidence-20261019T004648Z-windowserver-restore`

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

- High-effort Astra review completed the safety/adversarial pass on the repair code.
- Two fresh max-effort `sr claude proxy` review attempts produced no output and are
  treated as unavailable, not as a verdict.
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
- The preserved copied-session snapshot at
  `/Users/danielraffel/Library/Application Support/cmux/recovery-backup-20261019T005641Z-live-session/session-com.cmuxterm.app.debug.restore.openat.json`
  contains two windows, eight workspaces, and 83 panels (about 208 KB).
- Its restore fixture was imported with automatic provider replay disabled; no provider child processes were launched during the fixture check.
- The imported JSON contains no scrollback payload; the pressure vector is
  surface/terminal fan-out (83 imported panels), not a large scrollback blob.
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

The current repair worktree head is
[`ceaa0b9428b0dc1c0296f3c75cf9c08f679dabd0`](https://github.com/danielraffel/cmux/commit/ceaa0b9428b0dc1c0296f3c75cf9c08f679dabd0).
The code head for the implementation change is
[`63814044655fcac6f862ca86ee88fb346e6a2112`](https://github.com/danielraffel/cmux/commit/63814044655fcac6f862ca86ee88fb346e6a2112).
The earlier provider repair remains at
[`bd24baf383ba3ef3249866d58f93d454182b9a2f`](https://github.com/danielraffel/cmux/commit/bd24baf383ba3ef3249866d58f93d454182b9a2f),
with subsequent commits recording receipts and the custom-path fix.
It contains the restore identity and fallback hardening, the managed-binding
persistence validation, and the `cmux feed clear` revision-floor fix. The
portable CMUXAgentLaunch suite passes **883 tests in 100 suites**; the focused
agent-restore regression passes **8 tests**; and the Dock lifecycle suite passes
**54 tests**. Swift syntax, test wiring, and `git diff --check` also pass.
Astra reviewed the exact committed repair slice; its final adversarial pass
caught and corrected an overly broad compatibility bypass before this head was
recorded. Claude proxy review was attempted again but remained unavailable.

The adversarial pass also found a managed custom-Codex edge: legacy workspace
restore previously required the executable basename to be literally `codex`,
even when the durable launcher kind was `codex` and the captured executable
was a valid custom path. The routing API now accepts that launcher-kind
evidence while retaining provider-assignment ambiguity checks, and the
workspace path passes the launcher kind through. The new native regression
`testLegacySubrouterCodexRestoreAcceptsManagedCustomExecutable` passes.

The host still has eight WindowServer reports, all macOS bug type 409 watchdog
timeouts. At failure, cmux instances ranged from approximately 805 MB to
1.45 GB RSS and 207 to 343 threads; the October 18 protected instance was
approximately 1.06 GB and 279 threads. The October 18 WindowServer snapshot
contains no QEMU process, while the separate QEMU report is a SIGABRT in
`NSCGLSurface flushRect`/gfxstream presentation. This supports cmux restore and
resident-renderer fan-out as the primary pressure vector, with QEMU an optional
amplifier rather than a required cause.

The protected PID `49398`, socket, live JSONL, and backup were not touched.
The latest backup is 878,760,521 bytes with SHA-256
`808c48a047244efe244a2a0f271793a04bfbef6028f89d4f3bbc5d1163bc09ba`.
Native full app-target dogfood remains separate from these focused green gates
and must use a tagged isolated build; no claim is made that it has passed.

## M3/M5S external-storage comparison (2026-10-19)

The read-only hardware comparison found the same 4 TB WD_BLACK SN850X family
drive and verified SMART status on both hosts. The OWC Express 1M2 enclosure
firmware is not identical: M5S reports firmware `64.1` with micro-firmware
`1.11.0`, while M3 reports `61.61` with micro-firmware `1.7.0`. Both negotiate
USB4 at 80 Gb/s, so link speed alone does not explain the M5S-only stall. This
firmware difference is a concrete variable for an OWC support comparison, but
it is not yet a proven cause.

M5S still has `com.danielraffel.tartci.reclaim` running for more than five
hours (`disk_reclaim.py --json --fix`). Its own log records a 300-second Git
timeout under `/Volumes/Atelier/Code/pulp`, a `/Volumes/Atelier` scan timeout,
and no reclaimed paths. The long-lived `rescore_daily_until_2026-10-22.sh`
process also remains present. The reclaim launch agent is configured with
`LowPriorityIO=true` and `Nice=10`, but those safeguards do not prevent a
stalled filesystem call from holding the job indefinitely. These are confirmed
storage-stall amplifiers and cleanup targets, not evidence that the SSD has
failed. SMART remains `Verified`; `diskutil verifyVolume` is still blocked by
Sandbox/TCC and the fsync probe still hangs, so hardware is not fully ruled out.

The current read-only `tartci governor show` also matters for the fleet audit:
the role is `dev-overflow`, the TOML requests `background_share_cores = 12`,
and the resolved budget is 26 lease-capacity cores, 20 reserved for gates, and
6 background-share cores. The profile currently resolves `agent_floor_cores`
and `agent_floor_pool_cores` to 8. The profile file was modified at
`2026-10-18 10:47:22 -0700`, several hours before the October 18 crash, while
the governor TOML itself dates to October 1. This is a real configuration
change to correlate with workload pressure, but the governor does not explain
the WindowServer watchdog by itself; the storage timeouts and cmux resident
resource fan-out remain the stronger mechanisms.

## Native verification update (2026-10-19)

The isolated test build completed successfully with
`./scripts/test-unit.sh -derivedDataPath
$HOME/Library/Developer/Xcode/DerivedData/cmux-pr21423-tests build-for-testing`.
That compiled the `cmux` app target and `cmuxTests` at the repair head. The
native `SessionPersistenceResumeBindingTests` selection then executed **21
tests in one suite**, all passing. The run emitted existing AppKit/Swift
deprecation and concurrency warnings, but no repair-related compile or test
failure. The host's CoreSimulator framework is older than the installed Xcode;
that warning is irrelevant to this macOS destination.

The broad static `--affected` recipe is not a clean release gate because it
also selects the unrelated expired `conversation-sidebar-release` feature flag
(`reviewBy 2026-10-18`). All other 15 selected checks passed. That flag was not
changed as part of this repair.

The current-head native rerun used the `cmux-unit` scheme and selected the
restore persistence, live-owner admission, and issue-12775 regression suites.
The post-fix rerun executed **45 tests in 3 suites**, all passing, with the same benign
CoreSimulator-version warning on this host. This is the authoritative focused
receipt for the current repair head; the earlier 21-test persistence receipt
remains a subset of it.

The isolated `CMUXAgentLaunch` package suite also passed on this head: **883
tests in 100 suites**. It includes the lease-transfer tests proving that the
launched agent does not inherit the lease and that the exit watcher retains it
until the agent exits, plus the bounded persistence, provider-routing, and
Subrouter recovery coverage. The package runner also printed an initial legacy
XCTest summary of zero tests before executing the Swift Testing suites; the
authoritative result is the final 883-test Swift Testing run.

The tagged runtime dogfood attempt used
`CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag rootcause-restore
--launch`. The repository guard refused before build/launch because this
checkout has no authenticated dev credential file at
`~/.secrets/cmuxterm-dev.env`. No guard was bypassed and no second app instance
was launched; live copied-fixture dogfood remains pending that credential
setup.

## M5S wait-point sample (2026-10-19)

A read-only `sample` of reclaim PID `48898` captured it spending the entire
five-second sample in Python `os.access()`/libsystem `access`, rather than
using CPU or waiting on a network operation. This is direct evidence that its
recursive filesystem scan is blocked in the volume path. Its launch agent is
still `com.danielraffel.tartci.reclaim`, with `LowPriorityIO=true` and
`Nice=10`.

The rescore shell PID `20151` is not currently doing filesystem work: its only
child is `sleep 86400`, and it has near-zero CPU time after two days. That makes
it a stale workspace/process to account for, but not the active wait point in
the current storage failure. A later recheck found and terminated the orphaned
reclaim instance described below; the rescore shell remains untouched because
it is sleeping and its ownership has not been resolved.

The owned reclaim instance was then terminated with `SIGTERM` as a reversible,
scoped cleanup. Launchd recorded exit 15 and did not immediately restart it.
The M5S fsync probe still timed out for 20 seconds after reclaim stopped. That
rules out the reclaim process as the sole cause of the volume stall; it was an
amplifier and a source of additional blocked scans, while the underlying APFS,
bridge, or device path remains unhealthy.

A follow-up after cleanup still cannot complete
`os.listdir("/Volumes/Atelier")` within 20 seconds, while `diskutil info` can
read static metadata and continues to report the volume mounted, writable,
PCI-Express, and SMART `Verified`. This split is consistent with a
filesystem-operation or bridge-path stall rather than a full device
disappearance. No unmount, repair, or reboot has been attempted because active
worktrees and the rescore job still have open ownership that must be resolved
first.

A bounded `lsof /Volumes/Atelier` now returns, but it reports **229 PIDs across
24 paths** holding the volume. The largest groups are shells in
`pulp-windows-arm-module-timeout` (45), `pulp-forge-distortion-extract-20261018`
(40), `agent-worktrees/nodal-followup-20261018` (28), and the current
`cmux-rootcause-20261019` workspace (16). This explains why an unmount cannot
yet be treated as a routine repair. These are candidates for session-by-session
retirement after ownership is confirmed; broad termination would risk active
work and is not justified by the inventory alone.

## M5S cleanup recheck (2026-10-19T14:42Z)

The orphaned `disk_reclaim.py --json --fix` process was rechecked over SSH. It
was owned by `danielraffel`, had parent PID 1, had been running for nearly an
hour, and had no reported open file descriptors under `/Volumes/Atelier` before
the probe itself stalled. It was terminated with `SIGTERM` as a scoped,
reversible cleanup. A fresh bounded `os.listdir("/Volumes/Atelier")` immediately
afterward still failed with `InterruptedError` after 5.5 seconds. This is a
new confirmation that reclaim is an amplifier, not the underlying storage
failure. No protected cmux process was signaled.

The previously supplied M5S agent workspace reference
`workspace:1000060000` is no longer present in the live cmux workspace list,
so no message was sent to an unrelated workspace. Storage-dependent M5S
validation remains paused until bounded list, write, fsync, and `loop.pid`
probes pass; healthy-host Shipyard work is not blocked by this condition.

## M5S rescore cleanup recheck (2026-10-19T15:02Z)

The two-day orphaned `rescore_daily_until_2026-10-22.sh` shell was also
confirmed to have parent PID 1, owned by `danielraffel`, and sleeping with no
active child work. It was stopped with `SIGTERM` as a scoped cleanup. A fresh
bounded `os.listdir("/Volumes/Atelier")` still failed with `InterruptedError`
after 5.5 seconds. With both the reclaim scanner and stale rescore shell
removed and the same failure persisting, stale agent jobs are ruled out as the
sole cause. The underlying APFS/Thunderbolt bridge/device path remains the
next investigation target; no unmount or repair was attempted while 229 PIDs
still hold the volume across active worktrees.

## M5S completed-lane cleanup (2026-10-19T15:08Z)

Three detached recovery-lane process groups in the separate
`cmux-rootcause-20261019` worktree had been idle for more than 13 hours. Their
provider, crash, and governor status files were complete, so only those three
groups were sent `SIGTERM`; the protected PID `49398` was not touched. The
Atelier holder census fell from 229 to 214 PIDs. A bounded directory probe
still failed with `InterruptedError`, so reducing stale agent ownership has not
yet cleared the filesystem stall. The completed lane reports remain available
for the evidence review.

The same recheck ran `diskutil verifyVolume /dev/disk7s1` without an unmount.
macOS refused to start verification with Sandbox/TCC error `-69464` (the
operation is restricted by Privacy & Security settings). This is an access
limitation, not a filesystem-health result; SMART `Verified` and static
`diskutil info` remain the only available health evidence until a safe
authorized First Aid/verify window exists.

OWC's current [Express 1M2 troubleshooting guide](https://eshop.macsales.com/manuals/OWC-Express-1M2-troubleshooting-guide)
recommends isolating the enclosure on a direct USB-C/Thunderbolt port, removing
other external drives, and running First Aid from the bottom of the Disk Utility
hierarchy upward when a listed volume will not mount. M5S already negotiates the
expected 80 Gb/s USB4 link and remains mounted, so the guide's low-link-speed and
missing-device cases do not fit. First Aid/verify remains the next storage
operation, but it must wait until the active Atelier worktree ownership is
resolved and a safe unmount window exists.

The protected restore build also has a concrete process-fan-out signature:
**30 `cmux __restore-lease-watch` helpers** have been alive for about two
hours, one per restored Codex/Subrouter session, consuming approximately
**356 MB combined RSS**. Their parents are independent Codex/Subrouter
processes, not the protected app PID itself. This does not prove each watcher
is leaked, but it directly demonstrates that the old restore path makes session
count translate into resident processes and memory. It is consistent with the
WindowServer snapshots showing 279 cmux threads and supports validating the new
admission and hibernation logic against watcher count, not only JSON decode
time.

## Portable validation refresh (2026-10-19T14:57Z)

At commit [`3243eb4b82d51d74a2a3fce07b593a74dc9b527a`](https://github.com/danielraffel/cmux/commit/3243eb4b82d51d74a2a3fce07b593a74dc9b527a),
`swift test --package-path Packages/macOS/CMUXAgentLaunch --disable-sandbox`
rebuilt the package and passed **883 tests in 100 suites**. This refresh is
portable/package evidence only; the tagged full-app dogfood remains pending
authenticated dev credentials and has not been substituted by this result.

The same current checkout also ran
`swift test --package-path Packages/macOS/CmuxTerminal --disable-sandbox
--filter 'TerminalSurfaceRestoreSpawnSchedulerTests|TerminalSurfaceStartupRestorePolicyTests'`.
It rebuilt the terminal package and passed **23 tests in 2 suites**, including
the twelve-surface burst cadence, duplicate-readiness coalescing, deferred
agent admission, and input-demand promotion cases. Compiler deprecation and
unused-import warnings were pre-existing and did not fail the run.

A bounded `timeout 75 sr claude proxy` review was attempted against this exact
head with the protected process and backup explicitly excluded. It produced no
output before timeout, so Claude remains **unavailable**, not a review verdict.
