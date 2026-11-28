public import CoreGraphics

/// The layout a pane-edge drop produces, for the final-layout preview
/// (pane-drop-targets DESIGN.md (c)1) and for the ratios the drop sends, so
/// both come from one prediction. Nil when it cannot be predicted from the
/// layout alone (a column with rows, a pane not on this screen): the caller
/// shows the half.
///
/// The prediction follows what lands, in order:
/// 1. the daemon's move: the pane the drag empties leaves (its sibling takes
///    its parent's place, ratios kept), and the target splits along the
///    zone's axis at 0.5 with the new pane on the zone's side;
/// 2. (`evenSizing`) the close sizing `LayoutModel.apply` sends when that
///    tree arrives without the emptied pane (`CloseSizing`, unless
///    `equalizesClose` is false: a zoomed screen sends none);
/// 3. (`evenSizing`) the split's own even sizing, computed on the tree
///    without the emptied pane, as a keyboard split's is (`EvenSplitRatios`).
///    It wins where both name a split.
public nonisolated struct DropPreviewLayout: Sendable {
    /// The layout after the drop.
    public var layout: ScreenLayout
    /// The ratio intents the drop sends once its move landed (steps 2 and 3,
    /// clamped as `LayoutModel.setSplitRatio` clamps): they name existing
    /// splits only, and leave `layout`'s ratios on screen whatever order the
    /// close sizing of step 2 arrives in.
    public var ratioChanges: [SplitRatioChange]

    /// The placeholder id of the pane the drop creates.
    public static let newPane = PaneID(rawValue: "__drop-preview-pane")
    static let newSplit = SplitID(rawValue: "__drop-preview-split")

    public init?(splitting pane: PaneID, zone: PaneDropZone, in layout: ScreenLayout, removing: PaneID?, evenSizing: Bool,
                 equalizesClose: Bool = true) {
        guard let axis = zone.splitAxis else { return nil }
        let first = zone == .left || zone == .top
        let removing = removing == pane ? nil : removing
        var splitChanges: [SplitRatioChange] = []
        func split(_ root: SplitNode) -> SplitNode {
            let tree = removing.flatMap { root.removing($0) } ?? root
            if evenSizing { splitChanges = EvenSplitRatios.changes(splitting: pane, axis: axis, in: tree) }
            return tree.replacingLeaf(pane) { leaf in
                .split(Self.newSplit, axis: axis, ratio: 0.5, a: first ? .leaf(Self.newPane) : leaf, b: first ? leaf : .leaf(Self.newPane))
            }
        }
        let moved: ScreenLayout
        switch layout {
        case let .splits(root):
            guard root.contains(pane) else { return nil }
            moved = .splits(split(root))
        case let .columns(columns):
            guard columns.contains(where: { $0.root.contains(pane) }) else { return nil }
            var result: [LayoutColumn] = []
            for var column in columns {
                let holdsTarget = column.root.contains(pane)
                let holdsSource = removing.map(column.root.contains) ?? false
                guard holdsTarget || holdsSource else { result.append(column); continue }
                // A row's tree is not the column's root: the daemon splits inside the row.
                guard !column.hasRows else { return nil }
                if holdsTarget {
                    column.root = split(column.root)
                } else if let removing {
                    guard let rest = column.root.removing(removing) else { continue }  // the emptied column closes
                    column.root = rest
                }
                result.append(column)
            }
            moved = .columns(result)
        }
        let closeChanges = evenSizing && equalizesClose
            ? removing.map { CloseSizing(old: layout, new: moved).splitChanges(closing: $0) } ?? [] : []
        // One change per split, the split's own sizing last (it wins), clamped as the model clamps.
        var changes: [SplitRatioChange] = []
        for change in closeChanges + splitChanges where change.split != Self.newSplit {
            let ratio = min(max(change.ratio, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
            changes.removeAll { $0.split == change.split }
            changes.append(SplitRatioChange(split: change.split, ratio: ratio))
        }
        self.layout = changes.reduce(moved) { $0.settingRatio($1.ratio, for: $1.split) }
        ratioChanges = changes
    }
}
