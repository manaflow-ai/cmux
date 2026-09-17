/// One assigned workspace's selected screen and nested navigation preferences.
public struct BackendProjectionNavigationWorkspaceState: Codable, Equatable, Sendable {
    /// The canonical workspace identifier.
    public let workspaceID: WorkspaceID

    /// The canonical screen selected in the workspace.
    public let selectedScreenID: ScreenID

    /// Screen preferences in canonical screen order.
    public let screens: [BackendProjectionNavigationScreenState]

    /// Creates one workspace preference.
    ///
    /// - Parameters:
    ///   - workspaceID: The canonical workspace identifier.
    ///   - selectedScreenID: The selected canonical screen.
    ///   - screens: Screen preferences in canonical order.
    public init(
        workspaceID: WorkspaceID,
        selectedScreenID: ScreenID,
        screens: [BackendProjectionNavigationScreenState]
    ) {
        self.workspaceID = workspaceID
        self.selectedScreenID = selectedScreenID
        self.screens = screens
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_uuid"
        case selectedScreenID = "selected_screen_uuid"
        case screens
    }
}
