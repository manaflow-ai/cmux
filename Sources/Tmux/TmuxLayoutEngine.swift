import Foundation

/// Converts tmux N-ary layout trees to binary split trees compatible with Bonsplit.
///
/// tmux layouts are N-ary (a split can have 2+ children). Bonsplit uses binary
/// splits (exactly 2 children). Conversion uses right-folding:
///   N-ary [A, B, C, D] → binary split(A, split(B, split(C, D)))
///
/// Divider positions are computed from tmux cell dimensions, accounting for
/// tmux's 1-cell divider between adjacent panes.
enum TmuxLayoutEngine {

    // MARK: - Binary Tree

    /// A binary split tree node used as an intermediate representation.
    indirect enum BinaryNode {
        case leaf(paneId: Int, width: Int, height: Int, x: Int, y: Int)
        case split(orientation: SplitOrientation, first: BinaryNode, second: BinaryNode, dividerFraction: CGFloat)

        enum SplitOrientation {
            case horizontal  // left | right (children arranged side by side)
            case vertical    // top / bottom (children stacked)
        }

        /// All pane IDs in this subtree.
        var allPaneIds: [Int] {
            switch self {
            case .leaf(let paneId, _, _, _, _):
                return [paneId]
            case .split(_, let first, let second, _):
                return first.allPaneIds + second.allPaneIds
            }
        }
    }

    // MARK: - Conversion

    /// Convert a tmux N-ary layout tree to a binary tree.
    static func toBinary(_ node: TmuxLayoutNode) -> BinaryNode {
        switch node {
        case .pane(let leaf):
            return .leaf(
                paneId: leaf.paneId,
                width: leaf.width,
                height: leaf.height,
                x: leaf.x,
                y: leaf.y
            )

        case .horizontal(let split):
            return foldChildren(split.children, orientation: .horizontal)

        case .vertical(let split):
            return foldChildren(split.children, orientation: .vertical)
        }
    }

    /// Right-fold N children into a binary tree.
    ///
    /// Given children [A, B, C, D]:
    ///   split(A, split(B, split(C, D)))
    ///
    /// Divider position for each split is computed as:
    ///   firstChildCells / (firstChildCells + dividerCells + remainingCells)
    ///
    /// where dividerCells = 1 (tmux uses a 1-cell divider between panes).
    private static func foldChildren(
        _ children: [TmuxLayoutNode],
        orientation: BinaryNode.SplitOrientation
    ) -> BinaryNode {
        guard !children.isEmpty else {
            // Should never happen in valid tmux layouts
            return .leaf(paneId: -1, width: 0, height: 0, x: 0, y: 0)
        }

        if children.count == 1 {
            return toBinary(children[0])
        }

        if children.count == 2 {
            let first = toBinary(children[0])
            let second = toBinary(children[1])
            let fraction = dividerFraction(
                firstChild: children[0],
                allChildren: children,
                orientation: orientation
            )
            return .split(orientation: orientation, first: first, second: second, dividerFraction: fraction)
        }

        // 3+ children: fold right
        let first = toBinary(children[0])
        let rest = Array(children.dropFirst())
        let remaining = foldChildren(rest, orientation: orientation)
        let fraction = dividerFraction(
            firstChild: children[0],
            allChildren: children,
            orientation: orientation
        )
        return .split(orientation: orientation, first: first, second: remaining, dividerFraction: fraction)
    }

    /// Compute the divider fraction for the first child in a split.
    ///
    /// For horizontal splits, uses width. For vertical splits, uses height.
    /// Accounts for tmux's 1-cell divider between the first child and the rest.
    private static func dividerFraction(
        firstChild: TmuxLayoutNode,
        allChildren: [TmuxLayoutNode],
        orientation: BinaryNode.SplitOrientation
    ) -> CGFloat {
        let firstSize: Int
        let totalSize: Int

        switch orientation {
        case .horizontal:
            firstSize = firstChild.width
            totalSize = allChildren.reduce(0) { $0 + $1.width } + (allChildren.count - 1)  // +1 per divider
        case .vertical:
            firstSize = firstChild.height
            totalSize = allChildren.reduce(0) { $0 + $1.height } + (allChildren.count - 1)
        }

        guard totalSize > 0 else { return 0.5 }
        return CGFloat(firstSize) / CGFloat(totalSize)
    }

    // MARK: - Diffing

    /// Operations to transform the current layout to match a new one.
    enum LayoutOperation {
        /// A pane's dimensions changed but the topology is the same.
        case resize(paneId: Int, width: Int, height: Int)
        /// The layout topology changed — rebuild from scratch.
        case rebuild(layout: TmuxLayoutNode)
    }

    /// Diff two layout trees to determine the minimal operations needed.
    ///
    /// If the pane set and topology are identical, returns resize operations.
    /// Otherwise returns a single rebuild operation.
    static func diff(
        old: TmuxLayoutNode,
        new: TmuxLayoutNode
    ) -> [LayoutOperation] {
        let oldPanes = old.allPaneIds.sorted()
        let newPanes = new.allPaneIds.sorted()

        // If pane set differs, must rebuild
        guard oldPanes == newPanes else {
            return [.rebuild(layout: new)]
        }

        // If topology matches (same structure), check for size-only changes
        if topologyMatches(old, new) {
            return sizeChanges(old: old, new: new)
        }

        // Topology changed (e.g., split orientation flipped) — rebuild
        return [.rebuild(layout: new)]
    }

    /// Check if two layout trees have the same structural topology.
    private static func topologyMatches(_ a: TmuxLayoutNode, _ b: TmuxLayoutNode) -> Bool {
        switch (a, b) {
        case (.pane(let la), .pane(let lb)):
            return la.paneId == lb.paneId

        case (.horizontal(let sa), .horizontal(let sb)),
             (.vertical(let sa), .vertical(let sb)):
            guard sa.children.count == sb.children.count else { return false }
            return zip(sa.children, sb.children).allSatisfy { topologyMatches($0, $1) }

        default:
            return false
        }
    }

    /// Extract size-change operations for leaves that differ between old and new.
    private static func sizeChanges(old: TmuxLayoutNode, new: TmuxLayoutNode) -> [LayoutOperation] {
        var ops: [LayoutOperation] = []

        switch (old, new) {
        case (.pane(let la), .pane(let lb)):
            if la.width != lb.width || la.height != lb.height {
                ops.append(.resize(paneId: lb.paneId, width: lb.width, height: lb.height))
            }

        case (.horizontal(let sa), .horizontal(let sb)),
             (.vertical(let sa), .vertical(let sb)):
            for (childA, childB) in zip(sa.children, sb.children) {
                ops.append(contentsOf: sizeChanges(old: childA, new: childB))
            }

        default:
            break
        }

        return ops
    }
}
