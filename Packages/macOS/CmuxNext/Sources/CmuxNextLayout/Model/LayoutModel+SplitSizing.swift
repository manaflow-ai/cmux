public import CmuxNextDesign

/// `layout.splitSizing` (plans/cmux-next/column-sizing.md). A split keeps
/// its pane's half by default in cmux-tui; `even` follows it with ratio
/// intents that give every pane along the split axis of that chain an equal
/// share. Interim: one store op with a sizing policy replaces this once the
/// layout reducer crate has it.
extension LayoutModel {
    /// The override, else the live setting while `followsDesignMetrics` is
    /// on, else even.
    public var splitSizing: SplitSizing {
        splitSizingOverride ?? (followsDesignMetrics ? DesignSettings.shared.splitSizing : .even)
    }

    /// The ratio changes splitting `pane` along `axis` needs (empty for
    /// `halve`, or when the pane is not shown here). Compute before the
    /// split: they name existing splits only. `removing` is a pane the same
    /// move closes (a dragged tab's emptied pane): the changes are computed
    /// without it, as the drop preview shows (`DropPreviewLayout`, #22287).
    public func splitSizingChanges(splitting pane: PaneID, axis: SplitAxis, removing: PaneID? = nil) -> [SplitRatioChange] {
        guard splitSizing == .even, let layout = screen(containing: pane)?.layout else { return [] }
        let tree: SplitNode? = switch layout {
        case let .splits(root): root
        case .columns: layout.column(containing: pane)?.tree(containing: pane)
        }
        let pruned = removing.flatMap { $0 == pane ? nil : tree?.removing($0) } ?? tree
        return pruned.map { EvenSplitRatios.changes(splitting: pane, axis: axis, in: $0) } ?? []
    }

    /// Sends `changes` as ended divider intents (after the split succeeded).
    public func applySplitSizing(_ changes: [SplitRatioChange]) {
        for change in changes {
            setSplitRatio(change.split, ratio: change.ratio, transaction: .make(), phase: .ended)
        }
    }
}
