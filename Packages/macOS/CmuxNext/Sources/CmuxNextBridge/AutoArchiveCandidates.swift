public import CmuxNextDaemon
public import CmuxNextSidebar
import CmuxNextDesign
import Foundation

/// Auto-archive's view of the daemons (plans/cmux-next/auto-archive-DESIGN.md): one candidate per
/// workspace the sidebar document places, with its newest activity and what keeps it. Reads only;
/// the coordinator calls it once per pass, never per frame or keystroke.
@MainActor
public struct AutoArchiveCandidates {
    private let stores: [DaemonStore]
    private let title: @MainActor (WorkspaceModel) -> String

    /// `stores`: every machine's daemon store; `title`: the name a row shows (the App's shown name).
    public init(stores: [DaemonStore], title: @escaping @MainActor (WorkspaceModel) -> String = { $0.displayName }) {
        self.stores = stores
        self.title = title
    }

    /// The candidates of every workspace `placed` (the document's ref-to-item map) holds.
    public func candidates(placed: [SidebarDocWorkspaceRef: String]) -> [AutoArchivePlanner.Candidate] {
        var out: [AutoArchivePlanner.Candidate] = []
        for store in stores {
            for workspace in store.workspaces {
                guard let ref = SidebarDocSections.ref(of: workspace, session: store.registryID), let item = placed[ref] else { continue }
                out.append(candidate(workspace, item: item))
            }
        }
        return out
    }

    /// One workspace's candidate: the newest output, agent update or notification is its last
    /// activity; a running command or agent turn keeps it; unread, waiting and error ask for the person.
    func candidate(_ workspace: WorkspaceModel, item: String) -> AutoArchivePlanner.Candidate {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let newest: UInt64 = tabs.map { tab -> UInt64 in
            max(tab.lastOutputMs ?? 0, tab.agent?.updatedAtMs ?? 0, tab.notification?.createdAtMs ?? 0)
        }.max() ?? 0
        let asks: Bool = switch StatusMapping.shared.summary(tabs: tabs, status: workspace.status).state {
        case .waiting, .error: true
        default: false
        }
        return AutoArchivePlanner.Candidate(
            item: item, workspace: workspace.id, title: title(workspace),
            lastActive: newest == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(newest) / 1000),
            pinned: workspace.pinned,
            running: tabs.contains { $0.commandSinceMs != nil } || StatusMapping.shared.isWorking(tabs: tabs),
            needsAttention: asks || workspace.unreadCount > 0 || workspace.markedUnread)
    }
}
