public import CoreGraphics

/// The layout a pane-edge drop produces, for the final-layout preview
/// (pane-drop-targets DESIGN.md (c)1): the target pane split along the
/// zone's axis with the new pane on the zone's side at 0.5, the pane the
/// drag empties removed, and (`evenSizing`, for a caller whose commit sends
/// them) the even-sizing ratios computed on the tree without that pane. Nil
/// when it cannot be predicted from the layout alone (a column with rows, a
/// pane not on this screen): the caller shows the half.
public nonisolated struct DropPreviewLayout: Sendable {
    /// The layout after the drop.
    public var layout: ScreenLayout

    /// The placeholder id of the pane the drop creates.
    public static let newPane = PaneID(rawValue: "__drop-preview-pane")
    static let newSplit = SplitID(rawValue: "__drop-preview-split")

    public init?(splitting pane: PaneID, zone: PaneDropZone, in layout: ScreenLayout, removing: PaneID?, evenSizing: Bool) {
        guard let axis = zone.splitAxis else { return nil }
        let first = zone == .left || zone == .top
        let removing = removing == pane ? nil : removing
        func split(_ root: SplitNode) -> SplitNode {
            var tree = removing.flatMap { root.removing($0) } ?? root
            if evenSizing {
                for change in EvenSplitRatios.changes(splitting: pane, axis: axis, in: tree) {
                    tree = tree.settingRatio(change.ratio, for: change.split)
                }
            }
            return tree.replacingLeaf(pane) { leaf in
                .split(Self.newSplit, axis: axis, ratio: 0.5, a: first ? .leaf(Self.newPane) : leaf, b: first ? leaf : .leaf(Self.newPane))
            }
        }
        switch layout {
        case let .splits(root):
            guard root.contains(pane) else { return nil }
            self.layout = .splits(split(root))
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
            self.layout = .columns(result)
        }
    }
}
