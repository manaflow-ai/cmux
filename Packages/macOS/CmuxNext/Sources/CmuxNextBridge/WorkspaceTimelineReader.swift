import CmuxAgentBrands
public import CmuxNextDaemon
public import CmuxNextSidebar
import Foundation

/// Reads a workspace's timeline for its hover card (u3320): every tab's moments merged, newest
/// first. A terminal's come from the daemon roster (`AgentRoster.timelines`), a chat's from the
/// acpmux mirror (`AgentTurnStateStore.timeline(for:)`). Read when a card opens, never per frame.
@MainActor
public struct WorkspaceTimelineReader {
    private let turns: AgentTurnStateStore

    public init(turns: AgentTurnStateStore) {
        self.turns = turns
    }

    /// At most `limit` entries of `workspace`'s tabs, newest first.
    public func entries(_ workspace: WorkspaceModel, agents: AgentRoster, limit: Int) -> [SidebarTimelineEntry] {
        guard limit > 0 else { return [] }
        var merged: [SidebarTimelineEntry] = []
        for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
            let ref = tab.agentSession
            var timeline = ref.map(turns.timeline(for:)) ?? AgentTimeline()
            if let terminal = agents.timelines[tab.surface], ref == nil || timeline.events.isEmpty { timeline = terminal }
            let fallbackAgent = ref?.harness ?? agents.bySurface[tab.surface]?.agent
            merged += timeline.events.map { Self.entry($0, agent: $0.agent ?? fallbackAgent) }
        }
        merged.sort { $0.date > $1.date }
        if merged.count > limit { merged.removeLast(merged.count - limit) }
        return merged
    }

    static func entry(_ event: AgentTimelineEvent, agent: String?) -> SidebarTimelineEntry {
        let kind: SidebarTimelineEntry.Kind = switch event.kind {
        case .prompt: .prompt
        case .started: .started
        case .waiting: .waiting
        case .finished: .finished
        case .failed: .failed
        }
        return SidebarTimelineEntry(kind: kind, date: Date(timeIntervalSince1970: TimeInterval(event.atMs) / 1000),
                                    text: event.text, agent: agent.map(displayName), isNotice: event.isNotice)
    }

    /// "Claude Code" for "claude"; the id itself for an agent cmux does not list.
    static func displayName(_ id: String) -> String {
        AgentBrandCatalog.agents.first { $0.id == id.lowercased() }?.name ?? id
    }
}
