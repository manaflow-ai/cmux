import Bonsplit
import SwiftUI

/// Recursive split container that lays out one ``RemoteTmuxLayoutNode`` subtree,
/// sizing children in proportion to their tmux cell extents. The gaps between
/// children show the divider color so both horizontal and vertical separators
/// are visible.
@MainActor
struct RemoteTmuxLayoutContainer: View {
    let node: RemoteTmuxLayoutNode
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onClosePane: (Int) -> Void

    private let dividerThickness: CGFloat = 2

    var body: some View {
        switch node.content {
        case let .pane(paneId):
            leaf(paneId: paneId)
        case let .horizontal(children):
            splitStack(children: children, axis: .horizontal)
        case let .vertical(children):
            splitStack(children: children, axis: .vertical)
        }
    }

    @ViewBuilder
    private func leaf(paneId: Int) -> some View {
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
                    isFocused: isFocused && mirror.activePaneId == paneId,
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
            RemoteTmuxLayoutContainer(
                node: children[index],
                mirror: mirror,
                appearance: appearance,
                isFocused: isFocused,
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
