import Foundation

/// Each terminal's agent status (`agent-changed`, `list-agents`), and when its agent
/// last started a turn the person prompted (ms since 1970), for Jump to Last Prompt.
/// Kept by surface, so a tab a resync rebuilds keeps both, and the newest prompt time
/// stays when a reconnect re-seeds the agents.
public struct AgentRoster: Sendable {
    public private(set) var bySurface: [SurfaceID: AgentStatus] = [:]
    public private(set) var lastPromptBySurface: [SurfaceID: UInt64] = [:]

    /// Applies one `agent-changed`; false (and nothing changes) when it is older than the status
    /// held: an event held across a resync can arrive after the connect seed (cx-ag5.6.8).
    @discardableResult
    mutating func apply(_ status: AgentStatus) -> Bool {
        if let held = bySurface[status.surface], held.updatedAtMs > 0, status.updatedAtMs > 0,
           status.updatedAtMs < held.updatedAtMs { return false }
        notePrompt(from: bySurface[status.surface], to: status)
        bySurface[status.surface] = status
        return true
    }

    /// Replaces every status with `list` (after connect).
    mutating func seed(_ list: [AgentStatus]) {
        for status in list { notePrompt(from: bySurface[status.surface], to: status) }
        bySurface = Dictionary(list.map { ($0.surface, $0) }, uniquingKeysWith: { $1 })
    }

    private mutating func notePrompt(from old: AgentStatus?, to new: AgentStatus) {
        guard Self.startsPromptedTurn(from: old, to: new) else { return }
        let now = UInt64(exactly: (Date().timeIntervalSince1970 * 1000).rounded()) ?? 0
        let at = new.updatedAtMs > 0 ? new.updatedAtMs : now
        lastPromptBySurface[new.surface] = max(lastPromptBySurface[new.surface] ?? 0, at)
    }

    /// A hook-reported agent works only after a submitted prompt (`agent.turn.started`:
    /// UserPromptSubmit and its kin), so each hook `working` report with a new time is one.
    /// Other reporters say `working` through a turn too, so only their start of work
    /// counts; out of `blocked` is an approval resuming the same turn.
    static func startsPromptedTurn(from old: AgentStatus?, to new: AgentStatus) -> Bool {
        guard new.state == .working else { return false }
        if new.source == "hook" { return old?.state != .working || old?.updatedAtMs != new.updatedAtMs }
        return old?.state != .working && old?.state != .blocked
    }
}
