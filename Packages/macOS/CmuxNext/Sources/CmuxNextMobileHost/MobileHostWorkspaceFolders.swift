import CmuxNextCompat
import CmuxNextDaemon

/// The folders of the tabs this Mac's daemon lists now (absolute, deduplicated, in model order), which acpmux gets so a
/// phone's agent chat may start there (``MobileHostApproverSync/updateWorkspaceRoots(_:)``).
///
/// One observation per workspace (main-thread-scheduling.md section 3, O5): the workspace list is observed without
/// reading any workspace's fields, and each workspace's folders are their own observation, so a `cd` in one terminal
/// reads its workspace's tabs again, never every tab. acpmux gets the joined list only when it changed.
@MainActor final class MobileHostWorkspaceFolders {
    private var listTask: Task<Void, Never>?
    private var observed: ObservedItems<WorkspaceModel, [String]>?
    private var listed: [WorkspaceModel] = []
    private var send: (@MainActor ([String]) -> Void)?
    /// What `send` got last (nil: nothing yet).
    private var sent: [String]?

    init() {}

    /// Follows `workspaces` (nil: iPhone connections are off or nobody is signed in, so no folders) and hands `send`
    /// the folders each time they change.
    func follow(_ workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel]?, send: @escaping @MainActor ([String]) -> Void) {
        stop()
        self.send = send
        observed = ObservedItems(item: { Self.folders(of: $0) }, same: { $0 == $1 }, changed: { [weak self] in self?.settle() })
        // task-owner: the iPhone host service (lives as long as the app); re-reads the list on each workspace list change
        listTask = Task { [weak self] in
            for await trigger in ObservationStream({ ObservationTrigger(workspaces()) }) {
                guard let self else { return }
                listed = trigger.value ?? [] // off: no workspace is watched, and acpmux gets no folders
                settle()
            }
        }
    }

    func stop() {
        listTask?.cancel()
        listTask = nil
        observed?.cancelAll()
        observed = nil
        (listed, send, sent) = ([], nil, nil)
    }

    /// The listed workspaces' folders now: only workspaces new to the list are read (their own observations keep the
    /// rest); `send` runs only when the joined list changed.
    private func settle() {
        guard let observed, let send else { return }
        let folders = Self.joined(observed.items(for: listed, id: { "\(ObjectIdentifier($0))" }))
        guard folders != sent else { return }
        sent = folders
        send(folders)
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
