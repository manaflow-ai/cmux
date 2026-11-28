public import CmuxNextCloud
public import CmuxNextDaemon

public extension ChatMoves {
    /// A run starts moving chat tab `tab` of `store` to `machine` (nil: not known yet; ``reach(tab:machine:)``):
    /// `progress`'s lines go on its row. The run calls ``landed(tab:)`` when it moved; its `progress.end()` ends it.
    func begin(_ tab: TabModel, of store: DaemonStore, to machine: String?, progress: CloudMoveProgress) {
        let workspace = store.workspace(holdingTab: tab.id), tabID = tab.id
        begin(tab: tabID, workspace: workspace?.id, travels: workspace.map { $0.screens.flatMap(\.panes).flatMap(\.tabs).count == 1 } ?? false,
              machine: machine, store: store)
        progress.stepped = { [weak self] line, fraction in self?.show(tab: tabID, line: line, fraction: fraction) }
        progress.ended = { [weak self] in self?.end(tab: tabID) }
    }
}
