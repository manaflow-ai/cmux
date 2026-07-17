/// Right-associated binary view of tmux's n-ary layout.
public indirect enum RemoteTmuxNativeSplitTree: Sendable {
    case atomic(RemoteTmuxLayoutNode)
    case split(
        layout: RemoteTmuxLayoutNode,
        orientation: RemoteTmuxSplitOrientation,
        first: RemoteTmuxNativeSplitTree,
        second: RemoteTmuxNativeSplitTree
    )

    public init(layout: RemoteTmuxLayoutNode) {
        switch layout.content {
        case .pane:
            self = .atomic(layout)
        case .horizontal(let children):
            self = Self.joined(children: children, orientation: .horizontal)?
                .replacingTopLayout(with: layout) ?? .atomic(layout)
        case .vertical(let children):
            self = Self.joined(children: children, orientation: .vertical)?
                .replacingTopLayout(with: layout) ?? .atomic(layout)
        }
    }

    /// The synthesized join spans only the children's bounds; the ORIGINAL
    /// node's span also holds any window-edge title row tmux placed outside
    /// every child. The top of each joined group keeps the original node so
    /// span-derived accounting (actual gap cells, minimum spans) sees the
    /// coordinates tmux actually assigned. Nested synthesized joins keep
    /// their child-bounds — their gaps are interior by construction.
    private func replacingTopLayout(with layout: RemoteTmuxLayoutNode) -> RemoteTmuxNativeSplitTree {
        guard case .split(_, let orientation, let first, let second) = self else { return self }
        return .split(layout: layout, orientation: orientation, first: first, second: second)
    }

    public var layout: RemoteTmuxLayoutNode {
        switch self {
        case .atomic(let layout), .split(let layout, _, _, _):
            return layout
        }
    }

    /// Finds a pane and records whether the right-associated native tree gives
    /// it a split ancestor and resizable border along `orientation`.
    public func paneResizeContext(
        paneID: Int,
        orientation: RemoteTmuxSplitOrientation
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
                        context.trailingResizeTargetPaneID = first.resizeCommandTargetPaneID(
                            avoiding: orientation
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
                    context.leadingResizeTargetPaneID = first.resizeCommandTargetPaneID(
                        avoiding: orientation
                    )
                }
            }
            return context
        }
    }

    /// Tmux resizes the target pane's nearest split along the requested axis.
    /// Select a pane whose path reaches this subtree without crossing a nearer
    /// same-axis split; otherwise this ancestor cannot be addressed safely.
    /// Public because every resize-pane sender must apply this same rule:
    /// the control path routes through paneResizeContext, and the
    /// divider-drag path addresses a split's first subtree directly — naming
    /// a pane behind an inner same-axis split there made tmux resize the
    /// inner split instead of the dragged one.
    public func resizeCommandTargetPaneID(avoiding orientation: RemoteTmuxSplitOrientation) -> Int? {
        switch self {
        case .atomic(let pane):
            guard case .pane(let paneID) = pane.content else { return nil }
            return paneID
        case .split(_, let splitOrientation, let first, let second):
            guard splitOrientation != orientation else { return nil }
            return first.resizeCommandTargetPaneID(avoiding: orientation)
                ?? second.resizeCommandTargetPaneID(avoiding: orientation)
        }
    }

    private static func joined(
        children: [RemoteTmuxLayoutNode],
        orientation: RemoteTmuxSplitOrientation
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
        orientation: RemoteTmuxSplitOrientation
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
