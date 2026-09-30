public import CmuxNextDesign

extension LayoutModel {
    /// Failing-test stub: the rules land in the next commit.
    public var defaultColumnWidth: Double {
        defaultColumnWidthOverride ?? ColumnWidthPreset.defaultWidth
    }

    @discardableResult
    public func prepareNewColumn(nextTo pane: PaneID, removing: PaneID? = nil) -> Double {
        defaultColumnWidth
    }

    public func newColumn(after pane: PaneID? = nil) {
        guard let pane = pane ?? focusedPane else { return }
        intentHandler?(.newColumn(after: pane, width: prepareNewColumn(nextTo: pane)))
    }
}
