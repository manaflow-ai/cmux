/// What one close of tabs is, chosen once at the close and never mixed (Lawrence, cmux-ad m48,
/// 2026-11-06: "if we're closing the last tab in a workspace, the entire workspace should just
/// immediately close"). Every entry point of a tab close (Cmd-W, the tab's close button, the strip's
/// menu, the palette, the CLI and the control socket) reaches `CloseUndoToasts.close`, which takes
/// this decision over every pane of the closing tabs' workspace.
public enum TabCloseKind: Equatable, Sendable {
    /// Every pane keeps a tab: the strip takes the tabs out; the panes and the split do not move.
    case tabs
    /// A pane loses its last tab and the workspace keeps another pane with a tab: that pane closes
    /// as one unit on the pane-close spring (plans/cmux-next/close-animation/DESIGN.md).
    case panes
    /// The close leaves no tab in the workspace: the workspace closes as Close Workspace does, at
    /// once (its row leaves, the window shows the next workspace); no tab or pane motion runs in it.
    case workspace

    /// The kind of a close over every pane of its workspace: for each, whether the close takes tabs
    /// from it and whether it leaves it with no tab. A Home workspace never closes with its tabs.
    public init(panes: [(closing: Bool, empties: Bool)], home: Bool) {
        let emptied = panes.contains { $0.closing && $0.empties }, kept = panes.contains { !$0.empties }
        self = !emptied ? .tabs : kept || home ? .panes : .workspace
    }
}
