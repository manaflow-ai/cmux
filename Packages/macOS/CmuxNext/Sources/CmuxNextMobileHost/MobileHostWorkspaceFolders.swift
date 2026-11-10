import CmuxNextCompat
import CmuxNextDaemon

/// The folders of the tabs this Mac's daemon lists now (absolute, deduplicated, in model order), which acpmux gets so a
/// phone's agent chat may start there (``MobileHostApproverSync/updateWorkspaceRoots(_:)``).
@MainActor final class MobileHostWorkspaceFolders {
    private var task: Task<Void, Never>?

    init() {}

    /// Follows `workspaces` (nil: iPhone connections are off or nobody is signed in, so no folders) and hands `send`
    /// the folders each time they change.
    func follow(_ workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel]?, send: @escaping @MainActor ([String]) -> Void) {
        stop()
        // task-owner: the iPhone host service (lives as long as the app); re-reads the folders on each daemon tree change
        task = Task {
            for await folders in ObservationStream({ Self.joined((workspaces() ?? []).map(Self.folders(of:))) }) {
                send(folders)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One workspace's tab folders: absolute ones only, deduplicated, in model order.
    static func folders(of workspace: WorkspaceModel) -> [String] {
        var folders: [String] = []
        for screen in workspace.screens {
            for pane in screen.panes {
                for case let cwd? in pane.tabs.map(\.cwd) where cwd.hasPrefix("/") && !folders.contains(cwd) {
                    folders.append(cwd)
                }
            }
        }
        return folders
    }

    /// The workspaces' folders as one list, deduplicated, in workspace order.
    static func joined(_ folders: [[String]]) -> [String] {
        var seen = Set<String>()
        return folders.joined().filter { seen.insert($0).inserted }
    }
}
