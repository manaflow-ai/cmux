package import CmuxNextDaemon

/// The remembered tab of each pane of one window, as the window's saved record lists them, kept between two saves.
///
/// A save applies the selections that changed since the last one (`TabSelectionMemory.takeChanges`) and reads no
/// pane: nothing after a workspace or space switch, one entry after a tab switch. Every pane is read again only
/// when the panes themselves may differ: the window lists other workspaces, or a machine's tree gained or lost a
/// pane or has one in another screen or workspace (`DaemonStore.paneListRevision`). A daemon batch or snapshot that
/// changes neither (an agent's output, a title, a status, a tab that comes or goes, a workspace applied again)
/// reads nothing. Such changes land between any two actions of a live session, and each one made the next save
/// read every pane of the window on the main thread, before the frame of the action that asked for the save.
@MainActor
package struct TabSelectionRecord {
    /// The window's tab memory: a window opened again has another. Weak, so a freed one is never taken for a new one.
    private weak var memory: TabSelectionMemory?
    private var workspaces: [String] = []
    private var paneLists: [PaneListStamp] = []
    private var tabs: [String: String] = [:]
    /// Panes whose remembered tab a build of this record read, since it was made. A save reads the panes that
    /// changed, never the session's (`SpaceSwitchRecordSaveTests`).
    package private(set) var paneReads = 0

    package init() {}

    /// The remembered tab per pane of the window's `workspaces`.
    /// - Parameters:
    ///   - workspace: the record the app shows for a workspace id (the first machine's that lists it).
    ///   - lists: whether the window lists a workspace id.
    // perf-hot: 0.1ms workspace-switch (the save that each workspace, space and tab switch asks for: it reads no pane)
    package mutating func tabs(of memory: TabSelectionMemory, workspaces: [String], stores: [DaemonStore],
                               workspace: (String) -> WorkspaceModel?, lists: (String) -> Bool) -> [String: String] {
        let paneLists = stores.map { PaneListStamp(store: $0, revision: $0.paneListRevision) }
        // Taken on every path: the full read below reads the memory itself, which has these changes.
        let changes = memory.takeChanges()
        if self.memory === memory, self.workspaces == workspaces, self.paneLists.elementsEqual(paneLists, by: { $0.isSame(as: $1) }) {
            for (pane, tab) in changes {
                // As the full read finds a pane: in a workspace the window lists, in the record the app shows for it.
                let held = stores.contains { store in
                    guard let model = store.pane(idOrResource: pane), model.id == pane,
                          let holder = store.location(of: model)?.workspace else { return false }
                    return lists(holder.id) && workspace(holder.id) === holder
                }
                tabs[pane] = held ? tab : nil
            }
            return tabs
        }
        var selected: [String: String] = [:]
        for id in workspaces {
            for pane in workspace(id)?.screens.flatMap(\.panes) ?? [] {
                paneReads += 1
                if let tab = memory.selection(in: pane.id) { selected[pane.id] = tab }
            }
        }
        self.memory = memory
        (self.workspaces, self.paneLists, tabs) = (workspaces, paneLists, selected)
        return selected
    }
}

/// One machine's store and its pane list revision.
private struct PaneListStamp {
    /// Weak, so a freed store is never taken for a new one.
    weak var store: DaemonStore?
    var revision: UInt64

    /// Whether `other` is the same live store at the same revision.
    func isSame(as other: PaneListStamp) -> Bool {
        store != nil && store === other.store && revision == other.revision
    }
}
