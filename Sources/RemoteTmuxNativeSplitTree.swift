import Bonsplit
import Foundation

/// Right-associated binary view of tmux's n-ary layout, matching Bonsplit's split tree.
indirect enum RemoteTmuxNativeSplitTree: Sendable {
    case atomic(RemoteTmuxLayoutNode)
    case split(
        layout: RemoteTmuxLayoutNode,
        orientation: SplitOrientation,
        first: RemoteTmuxNativeSplitTree,
        second: RemoteTmuxNativeSplitTree
    )

    init(layout: RemoteTmuxLayoutNode) {
        switch layout.content {
        case .pane:
            self = .atomic(layout)
        case .horizontal(let children):
            self = Self.joined(children: children, orientation: .horizontal) ?? .atomic(layout)
        case .vertical(let children):
            self = Self.joined(children: children, orientation: .vertical) ?? .atomic(layout)
        }
    }

    var layout: RemoteTmuxLayoutNode {
        switch self {
        case .atomic(let layout), .split(let layout, _, _, _):
            return layout
        }
    }

    /// Finds a pane and records whether the right-associated native tree gives
    /// it a split ancestor and resizable border along `orientation`.
    func paneResizeContext(
        paneID: Int,
        orientation: SplitOrientation
    ) -> (
        pane: RemoteTmuxLayoutNode,
        hasSplitAncestor: Bool,
        hasLeadingBorder: Bool,
        hasTrailingBorder: Bool,
        leadingResizeTargetPaneID: Int?,
        trailingResizeTargetPaneID: Int?
    )? {
        switch self {
        case .atomic(let layout):
            guard case .pane(let candidateID) = layout.content,
                  candidateID == paneID else { return nil }
            return (layout, false, false, false, nil, nil)
        case .split(_, let splitOrientation, let first, let second):
            if var context = first.paneResizeContext(paneID: paneID, orientation: orientation) {
                if splitOrientation == orientation {
                    context.hasSplitAncestor = true
                    context.hasTrailingBorder = true
                    if context.trailingResizeTargetPaneID == nil {
                        context.trailingResizeTargetPaneID = second.leadingBoundaryPaneID(
                            along: orientation,
                            overlapping: context.pane
                        )
                    }
                }
                return context
            }
            guard var context = second.paneResizeContext(paneID: paneID, orientation: orientation) else {
                return nil
            }
            if splitOrientation == orientation {
                context.hasSplitAncestor = true
                context.hasLeadingBorder = true
                if context.leadingResizeTargetPaneID == nil {
                    context.leadingResizeTargetPaneID = first.trailingBoundaryPaneID(
                        along: orientation,
                        overlapping: context.pane
                    )
                }
            }
            return context
        }
    }

    private func trailingBoundaryPaneID(
        along orientation: SplitOrientation,
        overlapping target: RemoteTmuxLayoutNode
    ) -> Int? {
        let boundary = orientation == .horizontal
            ? layout.x + layout.width
            : layout.y + layout.height
        return trailingBoundaryPaneID(
            along: orientation,
            boundary: boundary,
            overlapping: target
        )
    }

    private func leadingBoundaryPaneID(
        along orientation: SplitOrientation,
        overlapping target: RemoteTmuxLayoutNode
    ) -> Int? {
        let boundary = orientation == .horizontal ? layout.x : layout.y
        return leadingBoundaryPaneID(
            along: orientation,
            boundary: boundary,
            overlapping: target
        )
    }

    private func leadingBoundaryPaneID(
        along orientation: SplitOrientation,
        boundary: Int,
        overlapping target: RemoteTmuxLayoutNode
    ) -> Int? {
        switch self {
        case .atomic(let pane):
            guard case .pane(let paneID) = pane.content else { return nil }
            let leadingEdge = orientation == .horizontal ? pane.x : pane.y
            let overlaps: Bool
            if orientation == .horizontal {
                overlaps = max(pane.y, target.y) < min(pane.y + pane.height, target.y + target.height)
            } else {
                overlaps = max(pane.x, target.x) < min(pane.x + pane.width, target.x + target.width)
            }
            return leadingEdge == boundary && overlaps ? paneID : nil
        case .split(_, _, let first, let second):
            return first.leadingBoundaryPaneID(
                along: orientation,
                boundary: boundary,
                overlapping: target
            ) ?? second.leadingBoundaryPaneID(
                along: orientation,
                boundary: boundary,
                overlapping: target
            )
        }
    }

    private func trailingBoundaryPaneID(
        along orientation: SplitOrientation,
        boundary: Int,
        overlapping target: RemoteTmuxLayoutNode
    ) -> Int? {
        switch self {
        case .atomic(let pane):
            guard case .pane(let paneID) = pane.content else { return nil }
            let trailingEdge = orientation == .horizontal
                ? pane.x + pane.width
                : pane.y + pane.height
            let overlaps: Bool
            if orientation == .horizontal {
                overlaps = max(pane.y, target.y) < min(pane.y + pane.height, target.y + target.height)
            } else {
                overlaps = max(pane.x, target.x) < min(pane.x + pane.width, target.x + target.width)
            }
            return trailingEdge == boundary && overlaps ? paneID : nil
        case .split(_, _, let first, let second):
            return first.trailingBoundaryPaneID(
                along: orientation,
                boundary: boundary,
                overlapping: target
            ) ?? second.trailingBoundaryPaneID(
                along: orientation,
                boundary: boundary,
                overlapping: target
            )
        }
    }

    private static func joined(
        children: [RemoteTmuxLayoutNode],
        orientation: SplitOrientation
    ) -> RemoteTmuxNativeSplitTree? {
        guard let last = children.last else { return nil }
        var result = RemoteTmuxNativeSplitTree(layout: last)
        for child in children.dropLast().reversed() {
            result = join(
                first: RemoteTmuxNativeSplitTree(layout: child),
                second: result,
                orientation: orientation
            )
        }
        return result
    }

    private static func join(
        first: RemoteTmuxNativeSplitTree,
        second: RemoteTmuxNativeSplitTree,
        orientation: SplitOrientation
    ) -> RemoteTmuxNativeSplitTree {
        let firstLayout = first.layout
        let secondLayout = second.layout
        let minX = min(firstLayout.x, secondLayout.x)
        let minY = min(firstLayout.y, secondLayout.y)
        let maxX = max(firstLayout.x + firstLayout.width, secondLayout.x + secondLayout.width)
        let maxY = max(firstLayout.y + firstLayout.height, secondLayout.y + secondLayout.height)
        let children = [firstLayout, secondLayout]
        let layout = RemoteTmuxLayoutNode(
            width: maxX - minX,
            height: maxY - minY,
            x: minX,
            y: minY,
            content: orientation == .horizontal
                ? .horizontal(children)
                : .vertical(children)
        )
        return .split(
            layout: layout,
            orientation: orientation,
            first: first,
            second: second
        )
    }
}
