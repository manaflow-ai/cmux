import CmuxAgentBrands
public import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

extension SidebarMapping {
    /// The agents acting in `tabs` right now (cx-gg84), one per live tab with
    /// presence, in pane order. While the presence toggle is off only the agents
    /// that drive the screen or a browser (`SidebarPresence.drive`) are listed: the
    /// row, tab and pane show those always (Lawrence 2026-11-07), and quieter
    /// activity stays behind the prototype toggle. Two agents of one kind share a
    /// name and differ by color, the same in the sidebar, tab chip and pane tag.
    func presence(_ tabs: [TabModel], enabled: Bool = SidebarTunables.presenceDots.value) -> [SidebarPresence] {
        tabs.compactMap { tab -> SidebarPresence? in
            guard !tab.dead, let presence = tab.presence, let activity = presence.activity else { return nil }
            let shown = Self.activity(activity)
            guard enabled || shown.drive != nil else { return nil }
            return SidebarPresence(
                id: presence.session ?? "surface-\(presence.surface)",
                name: Self.agentName(presence.agent),
                activity: shown,
                target: Self.target(path: presence.path, line: presence.line),
                tab: TabID(tab.id),
                // Computer Use stops through its host; a browser stops with its agent chat's turn. A terminal
                // agent's browser use stops in its terminal, where Go to takes the person.
                canStop: shown == .computerUse || (shown == .browsing && tab.agentSession != nil)
            )
        }
    }

    /// The color key of the agent acting in `tab` (its session, else its
    /// surface), the key every presence mark of that agent is colored by.
    /// Callers check the presence toggle themselves.
    public func presenceColorKey(_ tab: TabModel) -> String? {
        presence([tab], enabled: true).first?.id
    }

    /// The brand catalog's name for an adapter id, else the id capitalized.
    /// Every hook event names its adapter, so `?` only marks a broken feed.
    static func agentName(_ agent: String?) -> String {
        guard let agent, !agent.isEmpty else { return "?" }
        return AgentBrandCatalog.agents.first { $0.id == agent }?.name ?? agent.prefix(1).uppercased() + agent.dropFirst()
    }

    /// `file.ext:line`: the file name only, so a row tooltip stays short.
    static func target(path: String?, line: UInt64?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return line.map { "\(name):\($0)" } ?? name
    }

    static func activity(_ activity: AgentPresence.Activity) -> SidebarPresence.Activity {
        switch activity {
        case .thinking: .thinking
        case .editing: .editing
        case .reading: .reading
        case .running: .running
        case .browsing: .browsing
        case .computerUse: .computerUse
        case .waiting: .waiting
        }
    }
}
