import Bonsplit
import CmuxRemoteWorkspace
import SwiftUI

/// Recursive transient renderer that divides live pixels by assigned cell
/// weights until exact tmux frames are available.
@MainActor
struct RemoteTmuxProportionalSplit: View {
    let node: RemoteTmuxLayoutNode
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onClosePane: (Int) -> Void

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

    /// Children interleaved with cell-sized divider strips (the same chrome
    /// imposed mode draws), so the transient render is visually continuous
    /// with the imposed one: a vertical gap is the title strip of the panes
    /// below it (last-known labels pinned through the drag), a horizontal
    /// gap is a hairline separator column.
    @ViewBuilder
    private func splitStack(children: [RemoteTmuxLayoutNode], axis: Axis) -> some View {
        let weights = children.map { CGFloat(axis == .horizontal ? $0.width : $0.height) }
        let thickness = axis == .horizontal ? mirror.stripColumnWidthPt : mirror.stripRowHeightPt
        RemoteTmuxWeightedSplitLayout(axis: axis, weights: weights, spacing: thickness) {
            ForEach(children.indices, id: \.self) { index in
                if index > 0 {
                    RemoteTmuxTransientStrip(
                        axis: axis == .horizontal ? .vertical : .horizontal,
                        segments: axis == .vertical
                            ? RemoteTmuxTransientStrip.topEdgeSegments(
                                of: children[index], within: node, mirror: mirror
                            )
                            : [],
                        appearance: appearance
                    )
                }
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
    }
}
