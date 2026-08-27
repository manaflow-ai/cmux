public import Foundation

/// The exact notification owner targeted by a focused unread command.
///
/// Workspace IDs and window-Dock owner IDs intentionally occupy separate cases.
/// This prevents a focused Dock surface from being routed through workspace-only
/// panel lookup and mutation paths.
public enum FocusedNotificationTarget: Sendable, Equatable {
    /// A surface in a workspace, or the workspace itself when `surfaceId` is nil.
    case workspace(tabId: UUID, surfaceId: UUID?)

    /// An exact surface in a per-window Dock.
    case windowDock(WindowDockUnreadTarget)
}
