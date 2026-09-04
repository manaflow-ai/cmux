/// The working-directory source used when cmux creates a terminal surface.
public enum NewSurfaceWorkingDirectoryPolicy: String, CaseIterable, Sendable, SettingCodable {
    /// Use the currently selected pane's reported working directory.
    case inheritActivePane
    /// Use the directory captured when the workspace was created.
    case workspaceRoot
    /// Use ``DeclarativeTerminalConfiguration/workingDirectoryPath``.
    case fixedPath
}
