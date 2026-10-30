import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextLayout

/// The right column beside a pane as the window shows it, for ``RightColumnPlacement``: the panes
/// that start at its right edge and overlap its height, top to bottom. Only panes that take new
/// tabs count.
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

    /// The panes right of `source` in `content`, top to bottom, from the pane frames of the screen
    /// that holds `source`, active or not (``RightColumnPlacement/column(beside:frames:gap:)``),
    /// keeping those that take new tabs. Review of #28044 at bd2b918d: the active screen's frames
    /// read an empty column for a chat on a screen the person switched away from mid-open.
    static func panes(beside source: LayoutPaneID, in content: WorkspaceContentController) -> [LayoutPaneID] {
        RightColumnPlacement.column(beside: source, frames: content.layoutView.navigationFrames(ofScreenContaining: source))
            .filter { content.panes[$0]?.stripModel.showsNewTabButton == true }
    }
}
