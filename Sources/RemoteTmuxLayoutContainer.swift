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

    @ViewBuilder
    private func imposed(_ frames: RemoteTmuxMirrorFrames) -> some View {
        ZStack(alignment: .topLeading) {
            // Divider strips first (below the panes), one tmux separator cell
            // wide/tall, drawn in the divider color.
            ForEach(Array(frames.dividersPt.enumerated()), id: \.offset) { _, rect in
                Rectangle()
                    .fill(appearance.dividerColor)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            ForEach(node.paneIDsInOrder, id: \.self) { paneId in
                if let rect = frames.paneFramesPt[paneId] {
                    RemoteTmuxPaneLeaf(
                        paneId: paneId,
                        mirror: mirror,
                        appearance: appearance,
                        isVisibleInUI: isVisibleInUI,
                        portalPriority: portalPriority,
                        onClosePane: onClosePane
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: appearance.backgroundColor))
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
        let total = max(1, weights.reduce(0, +))
        GeometryReader { geo in
            let span = axis == .horizontal ? geo.size.width : geo.size.height
            let usable = max(1, span - dividerThickness * CGFloat(max(0, children.count - 1)))
            if axis == .horizontal {
                HStack(spacing: dividerThickness) {
                    childViews(children, weights: weights, total: total, usable: usable, axis: axis)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                VStack(spacing: dividerThickness) {
                    childViews(children, weights: weights, total: total, usable: usable, axis: axis)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(appearance.dividerColor)
    }

    @ViewBuilder
    private func childViews(
        _ children: [RemoteTmuxLayoutNode],
        weights: [CGFloat],
        total: CGFloat,
        usable: CGFloat,
        axis: Axis
    ) -> some View {
        ForEach(children.indices, id: \.self) { index in
            let dimension = usable * weights[index] / total
            RemoteTmuxProportionalSplit(
                node: children[index],
                mirror: mirror,
                appearance: appearance,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                onClosePane: onClosePane
            )
            .frame(
                width: axis == .horizontal ? dimension : nil,
                height: axis == .vertical ? dimension : nil
            )
        }
    }
}
