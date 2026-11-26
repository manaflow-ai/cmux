public import Foundation

/// A point-in-time summary of one cmux main window, surfaced by the
/// window-management control commands and the system tree so callers can
/// discover windows, their key/visible state, and the selected workspace
/// without holding an `NSWindow` or `TabManager` reference.
///
/// A pure `Sendable` value type so it crosses control-command and snapshot
/// boundaries freely; the app target builds it from live window/tab state.
public struct MainWindowSummary: Sendable {
    /// Stable identifier of the main window this summary describes.
    public let windowId: UUID
    /// Whether the window is the current key window.
    public let isKeyWindow: Bool
    /// Whether the window is currently visible on screen.
    public let isVisible: Bool
    /// Number of workspaces (tabs) open in the window.
    public let workspaceCount: Int
    /// Identifier of the window's selected workspace, if any.
    public let selectedWorkspaceId: UUID?

    /// Creates a summary of one main window's state.
    public init(
        windowId: UUID,
        isKeyWindow: Bool,
        isVisible: Bool,
        workspaceCount: Int,
        selectedWorkspaceId: UUID?
    ) {
        self.windowId = windowId
        self.isKeyWindow = isKeyWindow
        self.isVisible = isVisible
        self.workspaceCount = workspaceCount
        self.selectedWorkspaceId = selectedWorkspaceId
    }
}
