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

    /// Shows the sizing of a split the caller is about to show (Cmd-D, Cmd-Shift-D), in this
    /// turn and with nothing sent: the split and its chain's new sizes reach the window in one
    /// layout, so every pane of the chain moves on one spring from the key's frame
    /// (plans/cmux-next/split-spring-animation/DESIGN.md). The sizes stay over the daemon's
    /// snapshots until ``commitSplitSizing(_:)`` or ``cancelSplitSizing(_:)``.
    ///
    /// - Parameter changes: ``splitSizingChanges(splitting:axis:)``, computed before the split.
    /// - Returns: The pending sizing, for ``commitSplitSizing(_:)`` or ``cancelSplitSizing(_:)``.
    public func showSplitSizing(_ changes: [SplitRatioChange]) -> PendingSplitSizing {
        let sizing = PendingSplitSizing(changes: changes, transaction: .make())
        for change in changes {
            holdSplitRatio(change.split, ratio: change.ratio, transaction: sizing.transaction)
        }
        return sizing
    }

    /// The split landed: sends the sizing's ratio intents to the daemon, under the transaction
    /// that shows them, so its echo confirms what the window already shows (nothing moves). A
    /// split another gesture took over since (a divider drag) keeps that gesture's value.
    public func commitSplitSizing(_ sizing: PendingSplitSizing) {
        for change in sizing.changes where showsSplitRatio(change.split, of: sizing.transaction) {
            setSplitRatio(change.split, ratio: change.ratio, transaction: sizing.transaction, phase: .ended)
        }
    }

    /// The split was refused: the sizing goes away with it, and the chain shows the daemon's
    /// sizes again (the store undoes the split in the same turn).
    public func cancelSplitSizing(_ sizing: PendingSplitSizing) {
        rejectTransaction(sizing.transaction)
    }

    /// Shows `ratio` for `split` under `transaction` and sends nothing: a split's even sizing in
    /// the key's frame, before the daemon made the split (``showSplitSizing(_:)``). It stays over
    /// every daemon snapshot until ``setSplitRatio(_:ratio:transaction:phase:)`` ends it under the
    /// same transaction or ``rejectTransaction(_:)`` drops it.
    func holdSplitRatio(_ split: SplitID, ratio: Double, transaction: LayoutTransactionID) {
        let ratio = min(max(ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
        updateScreen(where: { $0.ratio(of: split) != nil }) { $0.settingRatio(ratio, for: split) }
        splitOverrides[split] = Override(value: ratio, transaction: transaction, ended: false)
    }

    /// Whether `split` still shows the value `transaction` set (no later gesture took it over).
    func showsSplitRatio(_ split: SplitID, of transaction: LayoutTransactionID) -> Bool {
        splitOverrides[split]?.transaction == transaction
    }
}
