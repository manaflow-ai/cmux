import Foundation

/// Each terminal's agent status (`agent-changed`, `list-agents`), and when its agent
/// last started a turn the person prompted (ms since 1970), for Jump to Last Prompt.
/// Kept by surface, so a tab a resync rebuilds keeps both, and the newest prompt time
/// stays when a reconnect re-seeds the agents.
///
/// Each terminal's recent history too (`timelines`, u3320): prompts, starts, waits and finished
/// turns, for the workspace hover card. Memory only, `AgentTimeline.limit` events per terminal and
/// `timelineSurfaceLimit` terminals, the one quiet longest dropped first.
public struct AgentRoster: Sendable {
    public private(set) var bySurface: [SurfaceID: AgentStatus] = [:]
    /// The same statuses by their terminal (`AgentStatus.terminalID`): a tab whose surface is not the
    /// one the daemon named (a restored or reopened terminal's new tab) finds its agent here.
    public private(set) var byTerminal: [ResourceID: AgentStatus] = [:]
    public private(set) var lastPromptBySurface: [SurfaceID: UInt64] = [:]
    public private(set) var timelines: [SurfaceID: AgentTimeline] = [:]
    /// The most terminals with a timeline.
    public static let timelineSurfaceLimit = 512

    /// Applies one `agent-changed`; false (and nothing changes) when it is older than the status
    /// held: an event held across a resync can arrive after the connect seed (cx-ag5.6.8).
    @discardableResult
    mutating func apply(_ status: AgentStatus) -> Bool {
        // The terminal's status held, under whichever surface it was named by before.
        let held = status.terminalID.flatMap { byTerminal[$0] } ?? bySurface[status.surface]
        if let held, held.updatedAtMs > 0, status.updatedAtMs > 0,
           status.updatedAtMs < held.updatedAtMs { return false }
        // From the status held for the terminal: a report that names a new surface (its first tab
        // closed) continues the same turn rather than starting one.
        notePrompt(from: held, to: status)
        noteTimeline(from: held, to: status)
        if let terminal = status.terminalID { byTerminal[terminal] = status }
        bySurface[status.surface] = status
        return true
    }

    /// The status of the agent that runs in `tab`: by its terminal, else by its surface (an older
    /// daemon's status, which names no terminal).
    @MainActor
    public func status(for tab: TabModel) -> AgentStatus? {
        tab.terminalResourceID.flatMap { byTerminal[$0] } ?? bySurface[tab.surface]
    }

    /// Replaces every status with `list` (after connect).
    mutating func seed(_ list: [AgentStatus]) {
        for status in list {
            notePrompt(from: bySurface[status.surface], to: status)
            noteTimeline(from: bySurface[status.surface], to: status)
        }
        bySurface = Dictionary(list.map { ($0.surface, $0) }, uniquingKeysWith: { $1 })
        byTerminal = Dictionary(list.compactMap { status in status.terminalID.map { ($0, status) } }, uniquingKeysWith: { $1 })
    }

    private static var nowMs: UInt64 { UInt64(exactly: (Date().timeIntervalSince1970 * 1000).rounded()) ?? 0 }

    private mutating func notePrompt(from old: AgentStatus?, to new: AgentStatus) {
        guard Self.startsPromptedTurn(from: old, to: new) else { return }
        let at = new.updatedAtMs > 0 ? new.updatedAtMs : Self.nowMs
        lastPromptBySurface[new.surface] = max(lastPromptBySurface[new.surface] ?? 0, at)
    }

    private mutating func noteTimeline(from old: AgentStatus?, to new: AgentStatus) {
        let events = AgentTimeline.events(from: old, to: new, nowMs: Self.nowMs)
        guard !events.isEmpty else { return }
        var timeline = timelines[new.surface] ?? AgentTimeline()
        for event in events { timeline.append(event) }
        timelines[new.surface] = timeline
        if timelines.count > Self.timelineSurfaceLimit, let quietest = timelines.min(by: { $0.value.lastMs < $1.value.lastMs })?.key {
            timelines[quietest] = nil
        }
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
