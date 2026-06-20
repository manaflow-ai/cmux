public import Foundation

/// Host seam through which ``AgentPIDLivenessSweepService`` reaches the live
/// per-window workspace tree it cannot own from the package.
///
/// The service owns only the periodic cadence and the off-main liveness probe
/// (`kill(pid, 0)`); both reading the per-workspace agent-PID map and applying
/// the stale-entry clears are irreducibly app-coupled (they touch the live
/// `Workspace` god objects, the process-wide `PortScanner`, and the
/// `AppDelegate` notification store), so they stay in the app target behind
/// this seam. The per-window `TabManager` is the single conformer; the service
/// calls back into it on the main actor.
///
/// **Why a snapshot in and a stale set out.** The probe must run off the main
/// actor (a `kill(2)` syscall per tracked PID across every workspace), so the
/// service takes a `Sendable` snapshot of the whole window's agent-PID map on
/// the main actor (``agentPIDSnapshot()``), probes it on a detached task, and
/// hands back the `(workspaceId, key)` pairs whose process is gone, each mapped
/// to the **probed dead pid**. The host then re-reads the live workspace and
/// applies the clears on the main actor (``applyStaleAgentPIDs(_:)``), so no
/// `Workspace` reference ever crosses the actor boundary and the apply observes
/// the workspace's current state, not the snapshot's. Carrying the probed pid
/// lets the apply clear a key only when `agentPIDs[key]` still equals it,
/// preserving the legacy synchronous read/clear atomicity across the new
/// suspension point.
///
/// **Why `@MainActor`.** Every legacy entry point already ran on the main
/// actor: the legacy `DispatchSource` timer handler hopped to
/// `DispatchQueue.main.async` before reading `tabs` and mutating each
/// workspace. Co-locating the snapshot read and the apply with their callers
/// (the rule from stage 3b: state lives where its callers live) turns every
/// bridge into a plain call.
@MainActor
public protocol AgentPIDLivenessSweepHosting: AnyObject {
    /// A `Sendable` snapshot of every workspace's agent-PID map in this window,
    /// keyed by workspace id then by status key. Lifts the read half of the
    /// legacy sweep loop (`for tab in tabs { for (key, pid) in tab.agentPIDs }`).
    ///
    /// Taken on the main actor so the detached probe never touches a live
    /// `Workspace`. A `pid <= 0` entry is included verbatim; the service treats
    /// it as stale exactly as the legacy `guard pid > 0` did.
    func agentPIDSnapshot() -> [UUID: [String: pid_t]]

    /// Applies the stale `(workspaceId, key) -> probedDeadPid` clears the
    /// off-main probe found, on the main actor. Lifts the write half of the
    /// legacy sweep loop: for each affected workspace it clears each stale key
    /// with `clearStatus: true, refreshPorts: false`, then refreshes the
    /// workspace's agent ports from the surviving PIDs, then clears that
    /// workspace's notifications.
    ///
    /// Re-reads the live workspace by id rather than trusting the snapshot, and
    /// clears a key only when the workspace's current `agentPIDs[key]` still
    /// equals the probed dead pid. A key reassigned to a fresh live pid by
    /// `recordAgentPID` during the off-main probe window therefore survives,
    /// matching the legacy synchronous read/clear atomicity. Keyed and ordered by
    /// `staleByWorkspace`; a workspace with no stale keys is never touched,
    /// matching the legacy `if !keysToRemove.isEmpty` guard.
    func applyStaleAgentPIDs(_ staleByWorkspace: [UUID: [String: pid_t]])
}
