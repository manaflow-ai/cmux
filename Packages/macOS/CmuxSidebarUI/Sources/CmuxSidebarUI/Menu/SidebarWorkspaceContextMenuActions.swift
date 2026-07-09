public import AppKit
public import Foundation

/// The closures the workspace context menu invokes for each of its buttons.
///
/// The owning sidebar row supplies these; they encapsulate every reach into the
/// live tab-manager, notification store, and app-delegate so
/// ``SidebarWorkspaceContextMenu`` stays a pure projection. Closures that need
/// the acted-on workspace ids receive them as arguments (the row passes the
/// targeted set), matching the legacy builder's call sites.
///
/// All closures are `@MainActor` because they mutate main-actor app state, and
/// the menu is itself rendered on the main actor.
@MainActor
public struct SidebarWorkspaceContextMenuActions {
    /// Resolves the swatch image shown next to a palette color (`#RRGGBB`).
    public let colorSwatchImage: (String) -> NSImage
    /// Toggles the pin state of the targeted workspaces.
    public let onPin: () -> Void
    /// Creates a new workspace group from the given ids.
    public let onNewGroup: ([UUID]) -> Void
    /// Moves the given ids into the group with the given group id.
    public let onMoveToGroup: ([UUID], UUID) -> Void
    /// Removes the given ids from their group.
    public let onRemoveFromGroup: ([UUID]) -> Void
    /// Begins renaming this workspace.
    public let onRename: () -> Void
    /// Removes this workspace's custom title.
    public let onRemoveCustomName: () -> Void
    /// Begins editing this workspace's description.
    public let onEditDescription: () -> Void
    /// Clears this workspace's custom description.
    public let onClearDescription: () -> Void
    /// Reconnects every remote target.
    public let onReconnect: () -> Void
    /// Disconnects every remote target.
    public let onDisconnect: () -> Void
    /// Applies a color hex (or clears it when `nil`) to the given ids.
    public let onApplyColor: (String?, [UUID]) -> Void
    /// Prompts for a custom color and applies it to the given ids.
    public let onChooseCustomColor: ([UUID]) -> Void
    /// Copies the given SSH error string to the pasteboard.
    public let onCopySshError: (String) -> Void
    /// Moves this workspace up one position.
    public let onMoveUp: () -> Void
    /// Moves this workspace down one position.
    public let onMoveDown: () -> Void
    /// Moves the given ids to the top of the list.
    public let onMoveToTop: ([UUID]) -> Void
    /// Moves the given ids to a new window.
    public let onMoveToNewWindow: ([UUID]) -> Void
    /// Moves the given ids to the window with the given window id.
    public let onMoveToWindow: ([UUID], UUID) -> Void
    /// Closes the given ids.
    public let onClose: ([UUID]) -> Void
    /// Closes every workspace except the given ids.
    public let onCloseOthers: ([UUID]) -> Void
    /// Closes every workspace below this one.
    public let onCloseBelow: () -> Void
    /// Closes every workspace above this one.
    public let onCloseAbove: () -> Void
    /// Marks the given ids read.
    public let onMarkRead: ([UUID]) -> Void
    /// Marks the given ids unread.
    public let onMarkUnread: ([UUID]) -> Void
    /// Clears the latest notification for the given ids.
    public let onClearLatestNotifications: ([UUID]) -> Void
    /// Opens a notification selected from the workspace notification submenu.
    public let onOpenNotification: (UUID) -> Void
    /// Copies the workspace ids of the given ids to the pasteboard.
    public let onCopyWorkspaceIds: ([UUID]) -> Void
    /// Copies the workspace links of the given ids to the pasteboard.
    public let onCopyWorkspaceLinks: ([UUID]) -> Void
    /// Reveals this workspace's directory in Finder.
    public let onShowInFinder: () -> Void

    /// Creates the context-menu action bundle.
    public init(
        colorSwatchImage: @escaping (String) -> NSImage,
        onPin: @escaping () -> Void,
        onNewGroup: @escaping ([UUID]) -> Void,
        onMoveToGroup: @escaping ([UUID], UUID) -> Void,
        onRemoveFromGroup: @escaping ([UUID]) -> Void,
        onRename: @escaping () -> Void,
        onRemoveCustomName: @escaping () -> Void,
        onEditDescription: @escaping () -> Void,
        onClearDescription: @escaping () -> Void,
        onReconnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void,
        onApplyColor: @escaping (String?, [UUID]) -> Void,
        onChooseCustomColor: @escaping ([UUID]) -> Void,
        onCopySshError: @escaping (String) -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        onMoveToTop: @escaping ([UUID]) -> Void,
        onMoveToNewWindow: @escaping ([UUID]) -> Void,
        onMoveToWindow: @escaping ([UUID], UUID) -> Void,
        onClose: @escaping ([UUID]) -> Void,
        onCloseOthers: @escaping ([UUID]) -> Void,
        onCloseBelow: @escaping () -> Void,
        onCloseAbove: @escaping () -> Void,
        onMarkRead: @escaping ([UUID]) -> Void,
        onMarkUnread: @escaping ([UUID]) -> Void,
        onClearLatestNotifications: @escaping ([UUID]) -> Void,
        onOpenNotification: @escaping (UUID) -> Void,
        onCopyWorkspaceIds: @escaping ([UUID]) -> Void,
        onCopyWorkspaceLinks: @escaping ([UUID]) -> Void,
        onShowInFinder: @escaping () -> Void
    ) {
        self.colorSwatchImage = colorSwatchImage
        self.onPin = onPin
        self.onNewGroup = onNewGroup
        self.onMoveToGroup = onMoveToGroup
        self.onRemoveFromGroup = onRemoveFromGroup
        self.onRename = onRename
        self.onRemoveCustomName = onRemoveCustomName
        self.onEditDescription = onEditDescription
        self.onClearDescription = onClearDescription
        self.onReconnect = onReconnect
        self.onDisconnect = onDisconnect
        self.onApplyColor = onApplyColor
        self.onChooseCustomColor = onChooseCustomColor
        self.onCopySshError = onCopySshError
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onMoveToTop = onMoveToTop
        self.onMoveToNewWindow = onMoveToNewWindow
        self.onMoveToWindow = onMoveToWindow
        self.onClose = onClose
        self.onCloseOthers = onCloseOthers
        self.onCloseBelow = onCloseBelow
        self.onCloseAbove = onCloseAbove
        self.onMarkRead = onMarkRead
        self.onMarkUnread = onMarkUnread
        self.onClearLatestNotifications = onClearLatestNotifications
        self.onOpenNotification = onOpenNotification
        self.onCopyWorkspaceIds = onCopyWorkspaceIds
        self.onCopyWorkspaceLinks = onCopyWorkspaceLinks
        self.onShowInFinder = onShowInFinder
    }
}
