public import Foundation

/// One destination window offered by the "Move Workspace to Window" submenu of
/// a sidebar row's context menu.
///
/// A `Sendable` value snapshot of an app-side window-move target. The owning
/// row builds these from the app's live window list and passes them into the
/// context-menu package view, which renders ``label`` and reports ``windowId``
/// back through a move closure. ``isCurrentWindow`` disables the row for the
/// window the menu was opened from.
public struct SidebarWindowMoveMenuItem: Identifiable, Equatable, Sendable {
    /// The destination window's identifier.
    public let windowId: UUID
    /// The localized label shown for the destination window.
    public let label: String
    /// Whether this entry is the window the menu was opened from.
    public let isCurrentWindow: Bool

    /// Stable identity for `ForEach`; equals ``windowId``.
    public var id: UUID { windowId }

    /// Creates a window-move menu item.
    /// - Parameters:
    ///   - windowId: The destination window's identifier.
    ///   - label: The localized display label.
    ///   - isCurrentWindow: Whether this is the current window (disabled).
    public init(windowId: UUID, label: String, isCurrentWindow: Bool) {
        self.windowId = windowId
        self.label = label
        self.isCurrentWindow = isCurrentWindow
    }
}
