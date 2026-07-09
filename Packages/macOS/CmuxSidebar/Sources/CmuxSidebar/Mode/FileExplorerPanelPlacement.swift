/// Where the file-explorer panel is hosted: the right sidebar or a workspace pane.
///
/// A pure value distinguishing the two file-explorer panel host contexts.
public enum FileExplorerPanelPlacement: Equatable {
    case rightSidebar
    case pane
}
