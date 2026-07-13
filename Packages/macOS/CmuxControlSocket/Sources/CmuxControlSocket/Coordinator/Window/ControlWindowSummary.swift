public import Foundation

/// A read-only snapshot of one main window, as the app target exposes it to
/// ``ControlCommandCoordinator`` through ``ControlCommandContext``.
///
/// Mirrors the app target's `AppDelegate.MainWindowSummary` without the package
/// importing the app target. The coordinator turns each summary into the
/// `window.list` payload row.
public struct ControlWindowSummary: Sendable, Equatable {
    /// The window's stable identifier.
    public let windowID: UUID
    /// Whether this is the key (frontmost-active) window.
    public let isKeyWindow: Bool
    /// Whether the window is currently on screen.
    public let isVisible: Bool
    /// How many workspaces the window currently holds.
    public let workspaceCount: Int
    /// The currently-selected workspace in this window, if any.
    public let selectedWorkspaceID: UUID?

    /// Creates a window summary.
    ///
    /// - Parameters:
    ///   - windowID: The window's stable identifier.
    ///   - isKeyWindow: Whether this is the key window.
    ///   - isVisible: Whether the window is on screen.
    ///   - workspaceCount: How many workspaces the window holds.
    ///   - selectedWorkspaceID: The selected workspace, if any.
    public init(
        windowID: UUID,
        isKeyWindow: Bool,
        isVisible: Bool,
        workspaceCount: Int,
        selectedWorkspaceID: UUID?
    ) {
        self.windowID = windowID
        self.isKeyWindow = isKeyWindow
        self.isVisible = isVisible
        self.workspaceCount = workspaceCount
        self.selectedWorkspaceID = selectedWorkspaceID
    }
}
