import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// The hover card's extra facts of a workspace row (`SidebarWorkspaceDetail`, cx-swovq).
extension SidebarMapping {
    /// `indicator` is the row's merged status; `agentTab` the tab the row names as its agent;
    /// `front` the tab the row stands for; `notification` the row's unread notification text
    /// (nil when the row hides unread state).
    func detail(tabs: [TabModel], indicator: StatusIndicatorState, agentTab: TabModel?, front: TabModel?,
                notification: String?, turns: AgentTurnStateStore = .shared) -> SidebarWorkspaceDetail {
        var detail = SidebarWorkspaceDetail()
        detail.activitySince = Self.activitySince(tabs: tabs, indicator: indicator, turns: turns)
        let chat = agentTab?.agentSession.flatMap(turns.detail(for:))
        detail.model = chat?.model
        detail.contextTokens = chat?.contextTokens
        detail.contextWindow = chat?.contextWindow
        detail.costUsd24h = chat?.costUsd24h
        // The task: the chat's running prompt, else the terminal agent's last prompt (memory
        // only in the daemon), else what a working program says it does (OSC 7501 title, msg).
        detail.task = chat?.prompt ?? agentTab?.agent?.lastPrompt ?? tabs.lazy.filter { ProgramStatusRecord.strongest($0.programStatus)?.state == .working }
            .compactMap { StatusMapping.shared.detail($0) }.first
        if case .waiting = indicator {
            // Only a program that waits says why; another tab's working record is no reason.
            let blocked = tabs.lazy.filter { ProgramStatusRecord.strongest($0.programStatus)?.state == .blocked }
                .compactMap { StatusMapping.shared.detail($0) }.first
            detail.needsInput = blocked ?? notification
        }
        if let front, front.kind == .pty, front.agent == nil, let since = Self.commandStart(front) {
            detail.command = process(front)
            detail.commandSince = Self.date(ms: since)
        }
        // What every agent chat in the workspace runs below its turn, as acpmux counts it.
        for chat in tabs.compactMap({ $0.agentSession.flatMap(turns.detail(for:)) }) {
            detail.subagentsRunning += chat.subagentsRunning
            detail.subagentNames += chat.subagentNames
            detail.commandsRunning += chat.commandsRunning
        }
        return detail
    }

    /// The running subagents and background commands of `tab`'s agent chat (acpmux's counts);
    /// zero for any other tab.
    static func running(_ tab: TabModel, turns: AgentTurnStateStore = .shared) -> (subagents: Int, commands: Int) {
        guard let chat = tab.agentSession.flatMap(turns.detail(for:)) else { return (0, 0) }
        return (chat.subagentsRunning, chat.commandsRunning)
    }

    /// When the row's state began: the earliest start among the tabs that report that state.
    static func activitySince(tabs: [TabModel], indicator: StatusIndicatorState, turns: AgentTurnStateStore) -> Date? {
        guard indicator.isVisible else { return nil }
        let mapping = StatusMapping.shared
        var starts: [UInt64] = []
        for tab in tabs {
            // The same reports the merged status reads (`StatusMapping.reports`): a detector that
            // yields to a program record, or a seen done record, adds no start.
            if let agent = tab.agent, let since = agent.sinceMs, let state = mapping.state(agent.state), same(state, indicator),
               !mapping.yieldsToProgram(agent, tab.programStatus) {
                starts.append(since)
            }
            if let record = ProgramStatusRecord.strongest(mapping.seen.visible(tab)), let state = mapping.state(record),
               same(state, indicator), let since = record.sinceMs {
                starts.append(since)
            }
            // A turn's start is when it began working; a turn that waits has no wait start here.
            if mapping.turn(tab) == .working, same(.working(progress: nil), indicator),
               let ref = tab.agentSession, let started = turns.detail(for: ref)?.turnStartedAtMs {
                starts.append(started)
            }
            if tab.agent == nil, tab.agentSession == nil, let since = commandStart(tab), same(.busy(progress: nil), indicator) {
                starts.append(since)
            }
        }
        return starts.filter { $0 > 0 }.min().map(date(ms:))
    }

    /// When the tab's running command started, counted from when this client saw it when the
    /// daemon's clock runs ahead (another machine), as `StatusMapping.command` does.
    static func commandStart(_ tab: TabModel) -> UInt64? {
        guard var since = tab.commandSinceMs else { return nil }
        if let seen = tab.commandSeenAt { since = min(since, UInt64(seen.timeIntervalSince1970 * 1000)) }
        return since
    }

    /// Two states of the same kind, whatever their progress or blocked kind.
    static func same(_ a: StatusIndicatorState, _ b: StatusIndicatorState) -> Bool {
        switch (a, b) {
        case (.idle, .idle), (.busy, .busy), (.paused, .paused), (.working, .working), (.waiting, .waiting),
             (.error, .error), (.success, .success): true
        default: false
        }
    }

    static func date(ms: UInt64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
