public import CmuxNextBridge
import CmuxAgentBrands
public import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

extension SidebarMapping {
    /// The agents acting in `tabs` right now (cx-gg84), one per live tab with
    /// presence, in pane order; none while the presence toggle is off, so
    /// hook traffic does no sidebar work then. Two agents of one kind share a
    /// name and differ by color, the same in the sidebar, tab chip and pane tag.
    func presence(_ tabs: [TabModel], enabled: Bool = SidebarTunables.presenceDots.value) -> [SidebarPresence] {
        guard enabled else { return [] }
        return tabs.compactMap { tab -> SidebarPresence? in
            guard !tab.dead, let presence = tab.presence, let activity = presence.activity else { return nil }
            return SidebarPresence(
                id: presence.session ?? "surface-\(presence.surface)",
                name: Self.agentName(presence.agent),
                activity: Self.activity(activity),
                target: Self.target(path: presence.path, line: presence.line)
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
