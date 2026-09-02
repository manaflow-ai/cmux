public import Foundation

/// Point size of a container or planned pane outer (AppKit-free).
public struct RemoteHerdrImposeSize: Hashable, Sendable {
    /// Width in host points.
    public var width: Double
    /// Height in host points.
    public var height: Double

    /// Creates a size.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Cell + chrome metrics used to turn cell rects into point extents.
///
/// Production hosts pass Ghostty/Bonsplit numbers. Tests may use zeros for
/// chrome and still exercise the ``plan(w) <= w`` invariant.
public struct RemoteHerdrImposeMetrics: Hashable, Sendable {
    /// Terminal cell width in points.
    public var cellWidth: Double
    /// Terminal cell height in points.
    public var cellHeight: Double
    /// Bonsplit divider thickness.
    public var dividerThickness: Double
    /// Native tab-strip height carried by every pane.
    public var tabBarHeight: Double
    /// Surface pad on the width axis.
    public var surfacePadWidth: Double
    /// Surface pad on the height axis.
    public var surfacePadHeight: Double
    /// Smallest pane extent the renderer will apply (0 disables the floor).
    public var minimumPaneExtent: Double

    /// Creates metrics. Chrome defaults to zero for synthetic tests.
    public init(
        cellWidth: Double,
        cellHeight: Double,
        dividerThickness: Double = 0,
        tabBarHeight: Double = 0,
        surfacePadWidth: Double = 0,
        surfacePadHeight: Double = 0,
        minimumPaneExtent: Double = 0
    ) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.dividerThickness = dividerThickness
        self.tabBarHeight = tabBarHeight
        self.surfacePadWidth = surfacePadWidth
        self.surfacePadHeight = surfacePadHeight
        self.minimumPaneExtent = minimumPaneExtent
    }
}

/// Right-associated binary split tree (tmux ``RemoteTmuxNativeSplitTree``).
public indirect enum RemoteHerdrDividerNode: Hashable, Sendable {
    /// One Herdr pane.
    case leaf(paneID: String, outer: RemoteHerdrImposeSize?)
    /// First child vs combined rest.
    case split(
        orientation: RemoteHerdrSplitOrientation,
        fraction: Double,
        firstExtent: Double?,
        first: RemoteHerdrDividerNode,
        second: RemoteHerdrDividerNode
    )
}

/// Horizontal (left/right) or vertical (top/bottom) split axis.
public enum RemoteHerdrSplitOrientation: String, Hashable, Sendable {
    /// Children left → right.
    case horizontal
    /// Children top → bottom.
    case vertical
}

/// Targeted +1 pane: split an existing leaf instead of rebuilding.
public struct RemoteHerdrLeafExpansion: Hashable, Sendable {
    /// Pane that already has a surface.
    public var existingPaneID: String
    /// Newly created pane.
    public var newPaneID: String
    /// Split axis.
    public var orientation: RemoteHerdrSplitOrientation
    /// True when the new pane is the first child.
    public var insertFirst: Bool
    /// Initial divider fraction.
    public var fraction: Double

    /// Creates an expansion.
    public init(
        existingPaneID: String,
        newPaneID: String,
        orientation: RemoteHerdrSplitOrientation,
        insertFirst: Bool,
        fraction: Double
    ) {
        self.existingPaneID = existingPaneID
        self.newPaneID = newPaneID
        self.orientation = orientation
        self.insertFirst = insertFirst
        self.fraction = fraction
    }
}

/// What the host must do to the Bonsplit tree before imposing extents.
public enum RemoteHerdrTreeAction: Hashable, Sendable {
    /// Rebuild the whole tree from the rendered layout.
    case rebuild
    /// Same shape — geometry-only sizing pass.
    case keep
    /// Split one existing leaf.
    case expandLeaf(RemoteHerdrLeafExpansion)
    /// Close one leaf pane.
    case removeLeaf(paneID: String)
}

/// In-flight ``pane.resize`` after a user divider drag (tmux hold).
public struct RemoteHerdrDividerDragHold: Hashable, Sendable {
    /// Host split identity (Bonsplit UUID string).
    public var splitKey: String
    /// Drag axis.
    public var axis: RemoteHerdrSplitOrientation
    /// Cell span sent to Herdr.
    public var targetCells: Int

    /// Creates a hold.
    public init(splitKey: String, axis: RemoteHerdrSplitOrientation, targetCells: Int) {
        self.splitKey = splitKey
        self.axis = axis
        self.targetCells = max(1, targetCells)
    }
}

/// One impose pass the host (or plugin ``set-ratio``) must apply.
public struct RemoteHerdrImposePlan: Hashable, Sendable {
    /// Tree mutate vs keep.
    public var treeAction: RemoteHerdrTreeAction
    /// Binary divider tree to impose.
    public var dividerTree: RemoteHerdrDividerNode
    /// Pane that should receive focus, if any.
    public var focusPaneID: String?
    /// Window title (host may apply when titleChanged).
    public var title: String
    /// Split to skip while a drag-resize is in flight.
    public var heldSplitKey: String?
    /// Depth-first divider fractions (plugin ``set-ratio`` order).
    public var fractions: [Double]

    /// Creates a plan.
    public init(
        treeAction: RemoteHerdrTreeAction,
        dividerTree: RemoteHerdrDividerNode,
        focusPaneID: String? = nil,
        title: String = "",
        heldSplitKey: String? = nil,
        fractions: [Double] = []
    ) {
        self.treeAction = treeAction
        self.dividerTree = dividerTree
        self.focusPaneID = focusPaneID
        self.title = title
        self.heldSplitKey = heldSplitKey
        self.fractions = fractions
    }
}

/// Host-agnostic Bonsplit impose planner (tmux ``imposeDividerPlan`` analogue).
///
/// AppKit applies the plan. This type owns the ssh-tmux contract:
/// right-associated binary tree, targeted leaf expand/remove, tmux +1
/// divider-cell fraction, ``plan(w) <= w``, and divider-drag hold/resolve.
public enum RemoteHerdrImpose {
    /// Keep a divider fraction inside the range Bonsplit accepts.
    public static func clampRatio(_ value: Double) -> Double {
        min(0.95, max(0.05, value))
    }

    /// Tmux ``dividerFraction``: first / (first + rest + 1 divider cell).
    public static func dividerFraction(firstSpan: Int, restSpans: [Int]) -> Double {
        let rest = restSpans.reduce(0) { $0 + max(0, $1) }
        let first = max(0, firstSpan)
        return clampRatio(Double(first) / Double(max(1, first + rest + 1)))
    }

    /// Parent a divider plan may divide: exact-fit frame bounded by the region.
    ///
    /// INVARIANT plan(w) <= w: never plan past the banked container.
    public static func regionBoundedPlanParent(
        render: RemoteHerdrImposeSize?,
        region: RemoteHerdrImposeSize?
    ) -> RemoteHerdrImposeSize? {
        guard let parent = render ?? region else { return nil }
        guard let region else { return parent }
        return RemoteHerdrImposeSize(
            width: min(parent.width, region.width),
            height: min(parent.height, region.height)
        )
    }

    /// True when split nesting and pane ids match (geometry ignored).
    public static func sameShapeAndPaneIDs(
        _ lhs: RemoteHerdrLayoutNode,
        _ rhs: RemoteHerdrLayoutNode
    ) -> Bool {
        switch (lhs.content, rhs.content) {
        case let (.pane(left), .pane(right)):
            return left == right
        case let (.horizontal(left), .horizontal(right)),
             let (.vertical(left), .vertical(right)):
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy { sameShapeAndPaneIDs($0, $1) }
        default:
            return false
        }
    }

    /// Decide rebuild vs keep vs targeted leaf expand/remove.
    public static func treeAction(
        previousRendered: RemoteHerdrLayoutNode?,
        rendered: RemoteHerdrLayoutNode
    ) -> RemoteHerdrTreeAction {
        guard let previousRendered else { return .rebuild }
        if sameShapeAndPaneIDs(previousRendered, rendered) {
            return .keep
        }
        let oldIDs = Set(previousRendered.paneIDsInOrder)
        let newIDs = Set(rendered.paneIDsInOrder)
        let added = newIDs.subtracting(oldIDs)
        let removed = oldIDs.subtracting(newIDs)
        if newIDs.count == oldIDs.count + 1, added.count == 1,
           let addedID = added.first,
           let expansion = leafExpansion(
               from: previousRendered,
               to: rendered,
               addedPaneID: addedID
           )
        {
            return .expandLeaf(expansion)
        }
        if oldIDs.count == newIDs.count + 1, removed.count == 1, let removedID = removed.first {
            return .removeLeaf(paneID: removedID)
        }
        return .rebuild
    }

    /// Find a +1 leaf expansion (tmux ``leafExpansion``).
    public static func leafExpansion(
        from oldNode: RemoteHerdrLayoutNode,
        to newNode: RemoteHerdrLayoutNode,
        addedPaneID: String
    ) -> RemoteHerdrLeafExpansion? {
        if case let .pane(existingID) = oldNode.content,
           let split = twoLeafSplit(newNode),
           split.paneIDs.contains(existingID),
           split.paneIDs.contains(addedPaneID)
        {
            return RemoteHerdrLeafExpansion(
                existingPaneID: existingID,
                newPaneID: addedPaneID,
                orientation: split.orientation,
                insertFirst: split.paneIDs.first == addedPaneID,
                fraction: split.fraction
            )
        }
        guard let oldChildren = splitChildren(oldNode),
              let newChildren = splitChildren(newNode),
              oldChildren.orientation == newChildren.orientation,
              oldChildren.children.count == newChildren.children.count
        else {
            return nil
        }
        for (oldChild, newChild) in zip(oldChildren.children, newChildren.children) {
            if let found = leafExpansion(from: oldChild, to: newChild, addedPaneID: addedPaneID) {
                return found
            }
        }
        return nil
    }

    /// Right-associated binary view of an n-ary Herdr layout.
    ///
    /// Returns `nil` when the layout has no addressable panes (empty split or
    /// empty pane id) — never synthesizes a leaf with `paneID == ""`.
    public static func binaryTree(
        _ node: RemoteHerdrLayoutNode,
        metrics: RemoteHerdrImposeMetrics? = nil,
        parent: RemoteHerdrImposeSize? = nil
    ) -> RemoteHerdrDividerNode? {
        switch node.content {
        case let .pane(paneID):
            let trimmed = paneID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .leaf(paneID: trimmed, outer: parent)
        case let .horizontal(children):
            return join(children: children, horizontal: true, metrics: metrics, parent: parent)
        case let .vertical(children):
            return join(children: children, horizontal: false, metrics: metrics, parent: parent)
        }
    }

    /// Depth-first divider fractions.
    public static func collectFractions(_ node: RemoteHerdrDividerNode) -> [Double] {
        switch node {
        case .leaf:
            return []
        case let .split(_, fraction, _, first, second):
            return [fraction] + collectFractions(first) + collectFractions(second)
        }
    }

    /// Start a divider-drag session (tmux ``splitTabBarDividerDragDidBegin``).
    public static func beginDividerDrag(
        splitKey: String,
        axis: RemoteHerdrSplitOrientation,
        assignedCells: Int
    ) -> RemoteHerdrDividerDragHold {
        RemoteHerdrDividerDragHold(splitKey: splitKey, axis: axis, targetCells: assignedCells)
    }

    /// Clear the hold when the reply landed or the split vanished.
    public static func resolveDividerHold(
        _ hold: RemoteHerdrDividerDragHold?,
        assignedCells: Int?,
        splitStillExists: Bool
    ) -> RemoteHerdrDividerDragHold? {
        guard let hold else { return nil }
        guard splitStillExists, let assignedCells else { return nil }
        if assignedCells == hold.targetCells { return nil }
        return hold
    }

    /// Convert a settled drag into ``pane.resize`` cells.
    ///
    /// A no-op (same cells) must not send — Herdr never replies to a no-op,
    /// and the hold would park forever.
    public static func endDividerDrag(
        draggedExtent: Double,
        axisSpan: Double,
        totalCells: Int,
        assignedCells: Int
    ) -> (cells: Int, shouldSend: Bool) {
        let cells = RemoteHerdrSizing().resizeCells(
            draggedExtent: draggedExtent,
            axisSpan: axisSpan,
            totalCells: totalCells
        )
        return (cells, cells != assignedCells)
    }

    /// Build the host impose plan for one rendered (visible) layout tree.
    /// Builds an impose plan for a rendered layout.
    ///
    /// Returns `nil` when the layout cannot produce an addressable divider tree
    /// (no panes / empty splits) — matching ``RemoteHerdrSessionMirror/fallbackLayout``.
    public static func plan(
        rendered: RemoteHerdrLayoutNode,
        previousRendered: RemoteHerdrLayoutNode? = nil,
        focusPaneID: String? = nil,
        title: String = "",
        metrics: RemoteHerdrImposeMetrics? = nil,
        renderSize: RemoteHerdrImposeSize? = nil,
        regionSize: RemoteHerdrImposeSize? = nil,
        hold: RemoteHerdrDividerDragHold? = nil
    ) -> RemoteHerdrImposePlan? {
        let parent = regionBoundedPlanParent(render: renderSize, region: regionSize)
        guard let tree = binaryTree(rendered, metrics: metrics, parent: parent) else {
            return nil
        }
        return RemoteHerdrImposePlan(
            treeAction: treeAction(previousRendered: previousRendered, rendered: rendered),
            dividerTree: tree,
            focusPaneID: focusPaneID,
            title: title,
            heldSplitKey: hold?.splitKey,
            fractions: collectFractions(tree)
        )
    }

    /// Impose plan from one ``RemoteHerdrWindowMirror/apply`` result.
    public static func plan(
        from result: RemoteHerdrReconcileResult,
        previousRendered: RemoteHerdrLayoutNode? = nil,
        title: String = "",
        metrics: RemoteHerdrImposeMetrics? = nil,
        renderSize: RemoteHerdrImposeSize? = nil,
        regionSize: RemoteHerdrImposeSize? = nil,
        hold: RemoteHerdrDividerDragHold? = nil
    ) -> RemoteHerdrImposePlan? {
        plan(
            rendered: result.renderedLayout,
            previousRendered: previousRendered,
            focusPaneID: result.focusPaneID,
            title: title,
            metrics: metrics,
            renderSize: renderSize,
            regionSize: regionSize,
            hold: hold
        )
    }

    private static func span(_ node: RemoteHerdrLayoutNode, horizontal: Bool) -> Int {
        horizontal ? node.width : node.height
    }

    private static func splitChildren(
        _ node: RemoteHerdrLayoutNode
    ) -> (orientation: RemoteHerdrSplitOrientation, children: [RemoteHerdrLayoutNode])? {
        switch node.content {
        case .pane:
            return nil
        case let .horizontal(children):
            return (.horizontal, children)
        case let .vertical(children):
            return (.vertical, children)
        }
    }

    private static func twoLeafSplit(
        _ node: RemoteHerdrLayoutNode
    ) -> (orientation: RemoteHerdrSplitOrientation, paneIDs: [String], fraction: Double)? {
        guard let split = splitChildren(node), split.children.count == 2 else { return nil }
        let paneIDs = split.children.compactMap { child -> String? in
            if case let .pane(id) = child.content { return id }
            return nil
        }
        guard paneIDs.count == 2 else { return nil }
        let horizontal = split.orientation == .horizontal
        return (
            split.orientation,
            paneIDs,
            dividerFraction(
                firstSpan: span(split.children[0], horizontal: horizontal),
                restSpans: [span(split.children[1], horizontal: horizontal)]
            )
        )
    }

    private static func join(
        children: [RemoteHerdrLayoutNode],
        horizontal: Bool,
        metrics: RemoteHerdrImposeMetrics?,
        parent: RemoteHerdrImposeSize?
    ) -> RemoteHerdrDividerNode? {
        let orientation: RemoteHerdrSplitOrientation = horizontal ? .horizontal : .vertical
        guard let first = children.first else {
            return nil
        }
        if children.count == 1 {
            return binaryTree(first, metrics: metrics, parent: parent)
        }
        let rest = Array(children.dropFirst())
        let firstSpan = span(first, horizontal: horizontal)
        let restSpan = rest.reduce(0) { $0 + span($1, horizontal: horizontal) }
        var firstSize: RemoteHerdrImposeSize?
        var secondSize: RemoteHerdrImposeSize?
        var measuredFirstExtent: Double?
        let fraction: Double
        if let parent, let metrics {
            let parentExtent = horizontal ? parent.width : parent.height
            let sized = firstExtent(
                firstSpan: firstSpan,
                restSpan: restSpan,
                parentExtent: parentExtent,
                metrics: metrics,
                horizontal: horizontal
            )
            measuredFirstExtent = sized.extent
            fraction = sized.fraction
            if horizontal {
                firstSize = RemoteHerdrImposeSize(width: sized.extent, height: parent.height)
                secondSize = RemoteHerdrImposeSize(
                    width: max(0, parent.width - sized.extent - metrics.dividerThickness),
                    height: parent.height
                )
            } else {
                firstSize = RemoteHerdrImposeSize(width: parent.width, height: sized.extent)
                secondSize = RemoteHerdrImposeSize(
                    width: parent.width,
                    height: max(0, parent.height - sized.extent - metrics.dividerThickness)
                )
            }
        } else {
            fraction = dividerFraction(
                firstSpan: firstSpan,
                restSpans: rest.map { span($0, horizontal: horizontal) }
            )
        }
        let restNode = rest.count == 1 ? rest[0] : combined(children: rest, horizontal: horizontal)
        guard let firstTree = binaryTree(first, metrics: metrics, parent: firstSize),
              let secondTree = binaryTree(restNode, metrics: metrics, parent: secondSize)
        else {
            return nil
        }
        return .split(
            orientation: orientation,
            fraction: fraction,
            firstExtent: measuredFirstExtent,
            first: firstTree,
            second: secondTree
        )
    }

    private static func firstExtent(
        firstSpan: Int,
        restSpan: Int,
        parentExtent: Double,
        metrics: RemoteHerdrImposeMetrics,
        horizontal: Bool
    ) -> (extent: Double, fraction: Double) {
        let available = parentExtent - metrics.dividerThickness
        if available <= 0 {
            let fraction = dividerFraction(firstSpan: firstSpan, restSpans: [restSpan])
            return (0, fraction)
        }
        let cell = horizontal ? metrics.cellWidth : metrics.cellHeight
        let pad = horizontal ? metrics.surfacePadWidth : metrics.surfacePadHeight
        let firstIdeal = Double(firstSpan) * cell + pad
        let restIdeal = Double(restSpan) * cell + pad
        let totalIdeal = firstIdeal + restIdeal
        if totalIdeal <= 0 {
            let fraction = dividerFraction(firstSpan: firstSpan, restSpans: [restSpan])
            return (available * fraction, fraction)
        }
        var raw = available * (firstIdeal / totalIdeal)
        let floor = metrics.minimumPaneExtent
        if floor > 0, available > 2 * floor {
            raw = min(available - floor, max(floor, raw))
        }
        raw = min(available, max(0, raw))
        let fraction = clampRatio(raw / available)
        return (raw, fraction)
    }

    private static func combined(
        children: [RemoteHerdrLayoutNode],
        horizontal: Bool
    ) -> RemoteHerdrLayoutNode {
        guard children.count > 1 else { return children[0] }
        let minX = children.map(\.x).min() ?? 0
        let minY = children.map(\.y).min() ?? 0
        let maxX = children.map { $0.x + $0.width }.max() ?? 0
        let maxY = children.map { $0.y + $0.height }.max() ?? 0
        return RemoteHerdrLayoutNode(
            width: maxX - minX,
            height: maxY - minY,
            x: minX,
            y: minY,
            content: horizontal ? .horizontal(children) : .vertical(children)
        )
    }
}
