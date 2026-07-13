import Foundation

/// Joins hook history and live process observations into restorable surface owners.
///
/// Agent lifecycle has one directional authority boundary:
///
/// ```text
/// provider hook ───────▶ semantic adapter ───────▶ turn + workload observations
/// process/shell event ─▶ bounded PID ancestry ───▶ session + run graph
///                                                       │
///                         ┌─────────────────────────────┴──────────────────────┐
///                         ▼                                                    ▼
///                child / unverified run                             verified surface root
///          own activity + subtree rollup only                 restore-authority candidate
///                                                                              │
///                    active passive workload ──▶ hibernation blocked           ▼
///                                                              surface continuation binding
/// ```
///
/// A child remains observable but never enters this index. Hibernation snapshots
/// the root continuation before terminating its process tree, then restoration
/// creates a new run for the same logical session. Forking copies continuation
/// intent into a new surface and records `forked` parentage without copying the
/// source surface's authority. A normal `/exit`, Ctrl-D, or exit-producing Ctrl-C
/// completes the run and clears restoration eligibility; a Stop hook that leaves
/// the process alive changes activity only.
///
/// ```text
/// ACTIVE + no work ──hibernate──▶ HIBERNATED ──resume──▶ ACTIVE (new run)
/// ACTIVE ────────────fork───────▶ ACTIVE (source) + ACTIVE (new surface root)
/// ACTIVE ──root process exit───────────────▶ ENDED + owned workloads cancelled
/// turn interrupted + root alive────────────▶ ACTIVE + INTERRUPTED (restorable)
/// ```
///
/// Observability is file-backed and does not wait on the app socket. Each cmux
/// app process exports one opaque runtime id to local and remote terminals:
///
/// ```text
/// cmux app launch ─▶ CMUX_RUNTIME_ID ─▶ terminal ─▶ agent hook ─▶ session run
///                                                               │
/// cmux agents ───────────────── current runtime id ──────────────┤──▶ current tree
/// cmux agents --all ─────────────────────────────────────────────┘──▶ retained history
/// ```
///
/// Runtime filtering is one string comparison per run. PID start-time checks
/// validate liveness only for displayed runs and never scan the process table.
enum AgentSessionLifecycleFlowDocumentation {}
