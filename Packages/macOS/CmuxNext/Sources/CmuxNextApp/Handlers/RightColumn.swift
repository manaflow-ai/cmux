import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextLayout

/// The right column beside a pane as the window shows it, for ``RightColumnPlacement``: the pane on
/// its right, and the panes above and below that one that also sit right of it, top to bottom.
/// Only panes that take new tabs count.
@MainActor
enum RightColumn {
    /// The right column beside `source`, measured: its panes (layout pane ids) and their widths.
    static func measure(beside source: PaneController) -> RightColumnPlacement.Column {
        guard let content = source.workspace else { return .init(sourceWidth: source.view.bounds.width) }
        let panes = panes(beside: source.layoutPaneID, in: content)
        var widths: [String: CGFloat] = [:]
        for pane in panes { widths[pane.rawValue] = content.panes[pane]?.view.bounds.width }
        return .init(sourceWidth: source.view.bounds.width, panes: panes.map(\.rawValue), widths: widths)
    }

    /// The panes right of `source` in `content`, top to bottom: the neighbour on its right, then
    /// the panes above and below it whose left neighbour is `source`.
    static func panes(beside source: LayoutPaneID, in content: WorkspaceContentController) -> [LayoutPaneID] {
        let neighbor = { (pane: LayoutPaneID, direction: LayoutDirection) in PaneHandlers.neighbor(of: pane, direction: direction, in: content) }
        guard let right = neighbor(source, .right), right != source else { return [] }
        var column = [right]
        for direction in [LayoutDirection.up, .down] {
            var edge = right
            while let next = neighbor(edge, direction), next != source, !column.contains(next), neighbor(next, .left) == source {
                if direction == .up { column.insert(next, at: 0) } else { column.append(next) }
                edge = next
            }
        }
        return column.filter { content.panes[$0]?.stripModel.showsNewTabButton == true }
    }
}
