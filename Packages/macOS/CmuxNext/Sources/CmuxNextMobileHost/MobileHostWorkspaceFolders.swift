import CmuxNextCompat
import CmuxNextDaemon

/// The folders of the tabs this Mac's daemon lists now (absolute, each once), which acpmux gets so a phone's agent chat
/// may start there (``MobileHostApproverSync/updateWorkspaceRoots(_:)``). acpmux keeps them as a set: their order
/// says nothing.
///
/// One observation per workspace (main-thread-scheduling.md section 3, O5): the workspace list is observed without
/// reading any workspace's fields, and each workspace's folders are their own observation, so a `cd` in one terminal
/// reads its workspace's tabs again, never every tab. acpmux gets the list only when its folders changed.
///
/// The work after one workspace's change does not grow with the session (the person's session has 826 workspaces): the
/// changed workspace's folders arrive as one change (`ObservedItems.Change`), and the list is updated for the folders
/// that came or went only, by how many workspaces list each folder. Only a change of the workspace list reads the
/// folders of every workspace. What still follows the count of folders: the request itself, which carries every folder
/// (`_acpmux/workspace_roots_set` has no form for one folder).
@MainActor final class MobileHostWorkspaceFolders {
    private var listTask: Task<Void, Never>?
    private var observed: ObservedItems<WorkspaceModel, [String]>?
    private var listed: [WorkspaceModel] = []
    private var send: (@MainActor ([String]) -> Void)?
    /// What `send` got last: every listed folder, each once.
    private var roots: [String] = []
    /// False until `send` got its first list (an empty first list is sent too).
    private var hasSent = false
    /// By folder: its place in ``roots``.
    private var places: [String: Int] = [:]
    /// By folder: how many listed workspaces list it. Right while each workspace is listed once (the store's are):
    /// a workspace listed two times has one observation and two counts until the next change of the list.
    private var holders: [String: Int] = [:]

    init() {}

    /// Follows `workspaces` (nil: iPhone connections are off or nobody is signed in, so no folders) and hands `send`
    /// the folders each time they change.
    func follow(_ workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel]?, send: @escaping @MainActor ([String]) -> Void) {
        stop()
        self.send = send
        observed = ObservedItems(item: { Self.folders(of: $0) }, same: { $0 == $1 },
                                 changedItem: { [weak self] change in self?.itemChanged(change) })
        // task-owner: the iPhone host service (lives as long as the app); re-reads the list on each workspace list change
        listTask = Task { [weak self] in
            for await trigger in ObservationStream({ ObservationTrigger(workspaces()) }) {
                guard let self else { return }
                listed = trigger.value ?? [] // off: no workspace is watched, and acpmux gets no folders
                listChanged()
            }
        }
    }

    func stop() {
        listTask?.cancel()
        listTask = nil
        observed?.cancelAll()
        observed = nil
        listed = []
        send = nil
        roots = []
        hasSent = false
        places = [:]
        holders = [:]
    }

    /// The workspace list changed: the listed workspaces' folders now. Only workspaces new to the list are read (their
    /// own observations keep the rest), but every listed workspace is visited, so this runs for a list change only.
    /// `send` runs only when the folders changed (the same folders in another order are the same roots for acpmux).
    private func listChanged() {
        guard let observed, let send else { return }
        let items = observed.items(for: listed, id: { "\(ObjectIdentifier($0))" })
        holders = [:]
        // A workspace's folders are each once (``folders(of:)``), so this counts workspaces, as ``itemChanged`` does.
        for folder in items.joined() { holders[folder, default: 0] += 1 }
        guard !hasSent || holders.count != places.count || holders.keys.contains(where: { places[$0] == nil }) else { return }
        roots = Self.joined(items)
        places = [:]
        for (place, folder) in roots.enumerated() { places[folder] = place }
        hasSent = true
        send(roots)
    }

    /// One workspace's folders changed: a folder that no workspace lists any more leaves the list (the last folder
    /// takes its place), a folder that no workspace listed joins at the end. No other workspace is visited; `send`
    /// runs only when a folder came or went.
    private func itemChanged(_ change: ObservedItems<WorkspaceModel, [String]>.Change) {
        guard let send else { return }
        let (before, now) = (Set(change.old), Set(change.new))
        let (gone, came) = (before.subtracting(now), now.subtracting(before))
        ObservationWork.visited(gone.count + came.count, "MobileHostWorkspaceFolders.join")
        var moved = false
        for folder in gone {
            guard let count = holders[folder] else { continue }
            holders[folder] = count > 1 ? count - 1 : nil
            guard count == 1, let place = places.removeValue(forKey: folder) else { continue }
            let last = roots.removeLast()
            if place < roots.count {
                roots[place] = last
                places[last] = place
            }
            moved = true
        }
        for folder in came {
            holders[folder, default: 0] += 1
            guard places[folder] == nil else { continue }
            places[folder] = roots.count
            roots.append(folder)
            moved = true
        }
        if moved { send(roots) }
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
