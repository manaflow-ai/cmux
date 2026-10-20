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
    /// split: they name existing splits only.
    public func splitSizingChanges(splitting pane: PaneID, axis: SplitAxis) -> [SplitRatioChange] {
        guard splitSizing == .even, let layout = screen(containing: pane)?.layout else { return [] }
        let tree: SplitNode? = switch layout {
        case let .splits(root): root
        case .columns: layout.column(containing: pane)?.tree(containing: pane)
        }
        return tree.map { EvenSplitRatios.changes(splitting: pane, axis: axis, in: $0) } ?? []
    }

    /// Sends `changes` as ended divider intents (after the split succeeded).
    public func applySplitSizing(_ changes: [SplitRatioChange]) {
        for change in changes {
            setSplitRatio(change.split, ratio: change.ratio, transaction: .make(), phase: .ended)
        }
    }

    /// Starts the sizing of a split the caller is about to show (Cmd-D, Cmd-Shift-D).
    ///
    /// - Parameter changes: ``splitSizingChanges(splitting:axis:)``, computed before the split.
    /// - Returns: The pending sizing, for ``commitSplitSizing(_:)`` or ``cancelSplitSizing(_:)``.
    public func showSplitSizing(_ changes: [SplitRatioChange]) -> PendingSplitSizing {
        PendingSplitSizing(changes: changes, transaction: .make())
    }

    /// The split landed: sends the sizing's ratio intents to the daemon.
    public func commitSplitSizing(_ sizing: PendingSplitSizing) {
        applySplitSizing(sizing.changes)
    }

    /// The split was refused: the sizing goes away with it.
    public func cancelSplitSizing(_ sizing: PendingSplitSizing) {}
}
