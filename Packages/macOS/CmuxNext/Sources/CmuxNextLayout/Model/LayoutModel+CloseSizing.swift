public import CmuxNextDesign

/// Sizing on close (Lawrence 2026-10-16, "panes should always equalize when we create and close
/// them"): with `layout.splitSizing` even, a closed pane's same-axis chain shares its space
/// equally again, as a split's chain does (`splitSizingChanges`). With `layout.newColumnWidth`
/// fitScreen, the scrolling columns that fit the viewport share it equally after a column closes.
/// Interim like the split side: ratio and width intents after the daemon's tree, until the layout
/// reducer has a sizing policy.
extension LayoutModel {
    /// Sends the sizing intents for the panes and columns that left between two daemon trees.
    /// `landed`: panes whose close this window showed (`showPaneClose`); their sizes are the landed
    /// close sizes (`noteLandedCloses`), sent once no close is pending on the screen.
    func applyCloseSizing(from old: [LayoutScreen], to new: [LayoutScreen], landed: Set<PaneID> = []) {
        struct Request: Encodable {
            var old: [PaneCloseRules.Screen], new: [PaneCloseRules.Screen], landed: [String], sizing: PaneCloseRules.Sizing
        }
        let sizing = closeSizing
        guard sizing.even || sizing.fits else { return }
        let request = Request(old: old.map(PaneCloseRules.Screen.init), new: new.map(PaneCloseRules.Screen.init),
                              landed: landed.map(\.rawValue).sorted(), sizing: sizing)
        guard let intents: PaneCloseRules.Intents = PaneCloseRules.ask("pane_close_sizing", request) else { return }
        applySplitSizing(intents.ratios.map { SplitRatioChange(split: SplitID($0.split), ratio: $0.ratio) })
        for resize in intents.widths {
            setColumnWidth(ColumnID(resize.column), width: resize.width, transaction: .make(), phase: .ended)
        }
    }
}

/// The even sizes a close leaves: the closed pane's sibling takes its parent's place, and the
/// same-axis chain around that place is equalized (Rust `pane_close_split_changes`,
/// `pane_close_column_resizes`).
nonisolated struct CloseSizing {
    let old: ScreenLayout
    let new: ScreenLayout

    private struct Request: Encodable { var old: PaneCloseRules.Wire, new: PaneCloseRules.Wire, pane: String }

    func splitChanges(closing pane: PaneID) -> [SplitRatioChange] {
        struct Reply: Decodable { var changes: [PaneCloseRules.Change] }
        let reply: Reply? = PaneCloseRules.ask("pane_close_split_changes", Request(old: .init(old), new: .init(new), pane: pane.rawValue))
        return reply?.changes.map { SplitRatioChange(split: SplitID($0.split), ratio: $0.ratio) } ?? []
    }

    /// Scrolling columns share the viewport equally after a scrolling column closed, while they fit it.
    func columnResizes() -> [ColumnResize] {
        struct Reply: Decodable { var resizes: [PaneCloseRules.Resize] }
        let reply: Reply? = PaneCloseRules.ask("pane_close_column_resizes", Request(old: .init(old), new: .init(new), pane: ""))
        return reply?.resizes.map { ColumnResize(column: ColumnID($0.column), width: $0.width) } ?? []
    }
}
