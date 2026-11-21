import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs

extension TabItemMapping {
    /// The tab chip's presence mark (cx-gg84): the agent's color key, what it drives and its spoken
    /// summary. An agent driving the screen or a browser shows always; other activity only with the
    /// agent presence toggle on (`SidebarMapping.presence`).
    func presence(_ tab: TabModel) -> TabPresence? {
        guard let sidebar = SidebarMapping.shared.presence([tab]).first else { return nil }
        let drive: TabPresence.Drive? = switch sidebar.drive {
        case .screen?: .screen
        case .browser?: .browser
        case nil: nil
        }
        return TabPresence(colorKey: sidebar.id, summary: sidebar.summary, drive: drive)
    }
}
