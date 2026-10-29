/// Which saved container left panels out of a session snapshot.
///
/// A pure persistence value: snapshot and restore code name the container
/// whose panels passed ``SessionPanelCap/sessionSnapshotMaxPanels``. The
/// localized restore warning for each case stays app-side.
public enum SessionSnapshotOmittedPanelContainer: Equatable, Sendable {
    /// The workspace's own panels.
    case workspace
    /// The Dock that belongs to a workspace.
    case workspaceDock
    /// The Dock that belongs to a window.
    case windowDock

    /// Stable diagnostic token for unified logging. Not user-facing.
    public var logLabel: String {
        switch self {
        case .workspace:
            return "workspace"
        case .workspaceDock:
            return "workspace-dock"
        case .windowDock:
            return "window-dock"
        }
    }
}
