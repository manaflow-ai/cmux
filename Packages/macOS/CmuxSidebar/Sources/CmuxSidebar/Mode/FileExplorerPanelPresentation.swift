/// What the file-explorer panel presents: the file tree or the find UI.
///
/// A pure, `Sendable` value with no AppKit, localization, or settings coupling.
/// Each case maps onto the corresponding ``RightSidebarMode`` so the panel can
/// report which right-sidebar mode it represents.
public enum FileExplorerPanelPresentation: Equatable, Sendable {
    /// The file tree.
    case files
    /// The find/search UI.
    case find

    /// The right-sidebar mode this presentation represents.
    public var rightSidebarMode: RightSidebarMode {
        switch self {
        case .files: return .files
        case .find: return .find
        }
    }
}
