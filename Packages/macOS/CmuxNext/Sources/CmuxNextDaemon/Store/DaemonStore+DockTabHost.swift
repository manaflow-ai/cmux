import Foundation

extension DaemonStore {
    /// ``DockTabHost`` of a tab asked for in `pane` of this tree.
    public func tabHost(for pane: PaneID) -> DockTabHost {
        guard let screen = screen(containing: pane) else { return .takesTabs }
        return DockTabHost.resolve(pane, columns: screen.columns, order: screen.layout.paneIDs, active: screen.defaultPane,
                                   focusedAt: { self.pane($0)?.focusedAt ?? 0 })
    }
}
