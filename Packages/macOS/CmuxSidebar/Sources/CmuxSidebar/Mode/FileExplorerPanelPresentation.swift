/// Which content the file-explorer panel presents: the file tree or the find UI.
///
/// A pure value selecting the file-explorer panel's mode. It maps to the
/// matching `RightSidebarMode` so a presentation can drive the right-sidebar
/// mode it corresponds to.
public enum FileExplorerPanelPresentation: Equatable {
    case files
    case find

    /// The right-sidebar mode this presentation corresponds to.
    public var rightSidebarMode: RightSidebarMode {
        switch self {
        case .files: return .files
        case .find: return .find
        }
    }
}
