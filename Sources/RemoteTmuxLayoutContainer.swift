import Bonsplit
import SwiftUI

/// Renders one mirrored tmux window's pane tree.
///
/// Two rendering modes, chosen by whether exact frames are available:
///
/// - **Imposed** (steady state): every pane gets EXACTLY the pixel frame its
///   the pane sizes tmux assigned occupy (``RemoteTmuxMirrorFrames``, edge-rail math in
///   device pixels), so each surface renders precisely the grid tmux thinks
///   it has and live `%output` paints faithfully — the render follows tmux's
///   layout. Placement is absolute in a fixed `topLeading` left-to-right space:
///   tmux coordinates are absolute, so sibling order must not flip under RTL
///   locales, and when a tmux layout briefly exceeds the container (a co-attached
///   client constraining the size) the overflow clips at the trailing edge.
///
/// - **Proportional** (transient): while the render constants are unknown or
///   tmux's layout doesn't yet match the pushed size (drag mid-flight, attach
///   settling), children divide the live pixels in proportion to their assigned
///   cells — always fits, tracks the window edge at frame rate, and snaps to
///   imposed frames when the matching tmux layout lands.
@MainActor
struct RemoteTmuxLayoutContainer: View {
    let node: RemoteTmuxLayoutNode
    let frames: RemoteTmuxMirrorFrames?
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onClosePane: (Int) -> Void

    var body: some View {
        Group {
            if let frames {
                imposed(frames)
            } else {
                RemoteTmuxProportionalSplit(
                    node: node,
                    mirror: mirror,
                    appearance: appearance,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onClosePane: onClosePane
                )
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .clipped()
    }

    private func imposed(_ frames: RemoteTmuxMirrorFrames) -> some View {
        // Panes without a computed frame (mid-teardown) are omitted from both
        // lists, keeping subview order aligned with the frame list the layout
        // places: dividers first (below the panes), then panes in tree order.
        let paneIds = node.paneIDsInOrder.filter { frames.paneFramesPt[$0] != nil }
        let orderedFrames = frames.dividersPt + paneIds.compactMap { frames.paneFramesPt[$0] }
        return RemoteTmuxImposedFrameLayout(frames: orderedFrames) {
            ForEach(Array(frames.dividersPt.enumerated()), id: \.offset) { _, _ in
                Rectangle().fill(appearance.dividerColor)
            }
            ForEach(paneIds, id: \.self) { paneId in
                RemoteTmuxPaneLeaf(
                    paneId: paneId,
                    mirror: mirror,
                    appearance: appearance,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onClosePane: onClosePane
                )
            }
        }
        .background(Color(nsColor: appearance.backgroundColor))
    }
}

/// Places every subview at a precomputed absolute frame (tmux's pane sizes in
/// points).
///
/// The layout's own size is always exactly the size its parent gives it —
/// never a size computed from the pane frames. That rule is load-bearing:
/// pane frames grow with the container, so if this view told its parent "I
/// am as big as my panes", any parent that listens (the workspace layout,
/// the window) would resize to fit the panes, the panes would grow to fit
/// the new size, and so on forever. It also has to stay shrinkable for the
/// same reason: a view that refuses to go below its pane widths stops
/// receiving size changes at all once the window gets narrow. When the panes
/// are momentarily bigger than the space (tmux hasn't applied our latest
/// size yet), the extra clips at the right/bottom edge, matching tmux's
/// top-left coordinate system.
private struct RemoteTmuxImposedFrameLayout: Layout {
    let frames: [CGRect]

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (index, subview) in subviews.enumerated() {
            // Count mismatch would mean the body's subview list drifted from
            // `frames`; hide the orphan rather than guessing a position.
            guard index < frames.count else {
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
                continue
            }
            let frame = frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}

/// One pane leaf: control header on top of the terminal panel. Shared by both
/// rendering modes.
@MainActor
struct RemoteTmuxPaneLeaf: View {
    let paneId: Int
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onClosePane: (Int) -> Void

    var body: some View {
        if let panel = mirror.panel(forPane: paneId),
           let syntheticPaneId = mirror.syntheticPaneID(forPane: paneId) {
            VStack(spacing: 0) {
                RemoteTmuxPaneHeader(
                    isActive: mirror.activePaneId == paneId,
                    appearance: appearance,
                    onFocus: { mirror.focus(pane: paneId) },
                    onSplitRight: { mirror.requestSplit(fromPane: paneId, vertical: false) },
                    onSplitDown: { mirror.requestSplit(fromPane: paneId, vertical: true) },
                    onClose: { onClosePane(paneId) }
                )
                TerminalPanelView(
                    panel: panel,
                    paneId: syntheticPaneId,
                    isFocused: mirror.activePaneId == paneId,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    isSplit: true,
                    appearance: appearance,
                    hasUnreadNotification: false,
                    terminalAgentContext: "",
                    onFocus: { mirror.focus(pane: paneId) },
                    onResumeAgentHibernation: {},
                    onAutoResumeAgentHibernation: {},
                    onTriggerFlash: {}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(paneId)
            .background(Color(nsColor: appearance.backgroundColor))
        } else {
            Color(nsColor: appearance.backgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The transient proportional renderer: recursive stacks dividing live pixels
/// by assigned cell weights. Never used at steady state — see
/// ``RemoteTmuxLayoutContainer`` for when each mode applies.
@MainActor
struct RemoteTmuxProportionalSplit: View {
    let node: RemoteTmuxLayoutNode
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onClosePane: (Int) -> Void

    private let dividerThickness: CGFloat = 2

    var body: some View {
        switch node.content {
        case let .pane(paneId):
            RemoteTmuxPaneLeaf(
                paneId: paneId,
                mirror: mirror,
                appearance: appearance,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                onClosePane: onClosePane
            )
        case let .horizontal(children):
            splitStack(children: children, axis: .horizontal)
        case let .vertical(children):
            splitStack(children: children, axis: .vertical)
        }
    }

    @ViewBuilder
    private func splitStack(children: [RemoteTmuxLayoutNode], axis: Axis) -> some View {
        let weights = children.map { CGFloat(axis == .horizontal ? $0.width : $0.height) }
        RemoteTmuxWeightedSplitLayout(axis: axis, weights: weights, spacing: dividerThickness) {
            ForEach(children.indices, id: \.self) { index in
                RemoteTmuxProportionalSplit(
                    node: children[index],
                    mirror: mirror,
                    appearance: appearance,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    onClosePane: onClosePane
                )
            }
        }
        .background(appearance.dividerColor)
    }
}

/// Divides the container along one axis proportionally to tmux's assigned
/// cells, with a fixed divider gap between children — the transient
/// fallback's split arithmetic as a proper `Layout` (single pass, no
/// geometry read-back into view state).
struct RemoteTmuxWeightedSplitLayout: Layout {
    let axis: Axis
    let weights: [CGFloat]
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let total = max(1, weights.reduce(0, +))
        let span = axis == .horizontal ? bounds.width : bounds.height
        let usable = max(1, span - spacing * CGFloat(max(0, subviews.count - 1)))
        var cursor = axis == .horizontal ? bounds.minX : bounds.minY
        for (index, subview) in subviews.enumerated() {
            let weight = index < weights.count ? weights[index] : 1
            let dimension = usable * weight / total
            let frame: CGRect = axis == .horizontal
                ? CGRect(x: cursor, y: bounds.minY, width: dimension, height: bounds.height)
                : CGRect(x: bounds.minX, y: cursor, width: bounds.width, height: dimension)
            subview.place(
                at: frame.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
            cursor += dimension + spacing
        }
    }
}
