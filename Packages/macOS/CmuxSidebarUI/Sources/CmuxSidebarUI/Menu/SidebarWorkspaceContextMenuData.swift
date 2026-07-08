public import Foundation
public import SwiftUI
public import CmuxSidebar

/// Immutable, `Sendable` snapshot of everything the workspace context menu
/// renders.
///
/// The owning sidebar row computes every label, id list, flag, and submenu list
/// once per body evaluation and passes them in, so ``SidebarWorkspaceContextMenu``
/// never reads a live workspace, tab-manager, or app-delegate store. Each field
/// mirrors a value the legacy `TabItemView.workspaceContextMenu` builder read
/// inline; grouping them here keeps the menu view a pure projection.
public struct SidebarWorkspaceContextMenuData: Sendable {
    /// The workspace ids the menu acts on (the multi-selection, or just this row).
    public let targetIds: [UUID]
    /// Whether more than one workspace is targeted; drives plural labels.
    public let isMulti: Bool

    /// Localized pin/unpin button label.
    public let pinLabel: String
    /// Whether the pin button is enabled (a pin state was resolved).
    public let pinEnabled: Bool

    /// Group snapshots offered by the "Move to Group" submenu.
    public let groups: [SidebarWorkspaceGroupMenuItem]
    /// Target ids eligible for grouping (group anchors excluded).
    public let eligibleGroupTargetIds: [UUID]
    /// Shared group id of every eligible target, or `nil` when they differ.
    public let allTargetsInSameGroupId: UUID?
    /// Whether any eligible target is currently in a group.
    public let hasAnyGroupedTarget: Bool
    /// Key equivalent for the new-group action, if bound.
    public let groupSelectedShortcutKey: KeyEquivalent?
    /// Modifiers for the new-group action.
    public let groupSelectedShortcutModifiers: EventModifiers

    /// Key equivalent for the rename action, if bound.
    public let renameShortcutKey: KeyEquivalent?
    /// Modifiers for the rename action.
    public let renameShortcutModifiers: EventModifiers
    /// Whether the workspace has a custom title (shows "Remove Custom Name").
    public let hasCustomTitle: Bool

    /// Key equivalent for the edit-description action, if bound.
    public let editDescriptionShortcutKey: KeyEquivalent?
    /// Modifiers for the edit-description action.
    public let editDescriptionShortcutModifiers: EventModifiers
    /// Whether the workspace has a custom description (shows "Clear Description").
    public let hasCustomDescription: Bool

    /// Whether any remote targets exist (shows reconnect/disconnect section).
    public let hasRemoteContextMenuTargets: Bool
    /// Localized reconnect button label.
    public let reconnectLabel: String
    /// Localized disconnect button label.
    public let disconnectLabel: String
    /// Whether every remote target is already connecting (disables reconnect).
    public let allRemoteTargetsConnecting: Bool
    /// Whether every remote target is already disconnected (disables disconnect).
    public let allRemoteTargetsDisconnected: Bool

    /// Whether the workspace has a custom color (shows "Clear Color").
    public let hasCustomColor: Bool
    /// The selectable color swatches.
    public let colorPalette: [SidebarWorkspaceColorMenuItem]

    /// The copyable SSH error string, if any (shows "Copy SSH Error").
    public let copyableSidebarSSHError: String?

    /// Whether this is the first row (disables Move Up / Close Above).
    public let isFirstRow: Bool
    /// Whether this is the last row (disables Move Down / Close Below).
    public let isLastRow: Bool

    /// Destination windows offered by the "Move to Window" submenu.
    public let windowMoveTargets: [SidebarWindowMoveMenuItem]

    /// Key equivalent for the close action, if bound.
    public let closeShortcutKey: KeyEquivalent?
    /// Modifiers for the close action.
    public let closeShortcutModifiers: EventModifiers
    /// Localized close button label.
    public let closeLabel: String
    /// Whether "Close Other Workspaces" is disabled.
    public let closeOthersDisabled: Bool

    /// Localized mark-read button label.
    public let markReadLabel: String
    /// Localized mark-unread button label.
    public let markUnreadLabel: String
    /// Localized clear-latest-notification button label.
    public let clearLatestNotificationLabel: String
    /// Whether any target can be marked read (enables the button).
    public let canMarkRead: Bool
    /// Whether any target can be marked unread (enables the button).
    public let canMarkUnread: Bool
    /// Whether any target has a latest notification to clear.
    public let hasLatestNotifications: Bool
    /// Notifications shown in the workspace notification submenu.
    public let workspaceNotifications: [SidebarWorkspaceNotificationMenuItem]

    /// Localized copy-workspace-id button label.
    public let copyWorkspaceIDLabel: String
    /// Localized copy-workspace-link button label.
    public let copyWorkspaceLinkLabel: String

    /// Whether a Finder directory exists (enables "Show in Finder").
    public let canShowInFinder: Bool

    /// Creates the context-menu data snapshot.
    public init(
        targetIds: [UUID],
        isMulti: Bool,
        pinLabel: String,
        pinEnabled: Bool,
        groups: [SidebarWorkspaceGroupMenuItem],
        eligibleGroupTargetIds: [UUID],
        allTargetsInSameGroupId: UUID?,
        hasAnyGroupedTarget: Bool,
        groupSelectedShortcutKey: KeyEquivalent?,
        groupSelectedShortcutModifiers: EventModifiers,
        renameShortcutKey: KeyEquivalent?,
        renameShortcutModifiers: EventModifiers,
        hasCustomTitle: Bool,
        editDescriptionShortcutKey: KeyEquivalent?,
        editDescriptionShortcutModifiers: EventModifiers,
        hasCustomDescription: Bool,
        hasRemoteContextMenuTargets: Bool,
        reconnectLabel: String,
        disconnectLabel: String,
        allRemoteTargetsConnecting: Bool,
        allRemoteTargetsDisconnected: Bool,
        hasCustomColor: Bool,
        colorPalette: [SidebarWorkspaceColorMenuItem],
        copyableSidebarSSHError: String?,
        isFirstRow: Bool,
        isLastRow: Bool,
        windowMoveTargets: [SidebarWindowMoveMenuItem],
        closeShortcutKey: KeyEquivalent?,
        closeShortcutModifiers: EventModifiers,
        closeLabel: String,
        closeOthersDisabled: Bool,
        markReadLabel: String,
        markUnreadLabel: String,
        clearLatestNotificationLabel: String,
        canMarkRead: Bool,
        canMarkUnread: Bool,
        hasLatestNotifications: Bool,
        workspaceNotifications: [SidebarWorkspaceNotificationMenuItem],
        copyWorkspaceIDLabel: String,
        copyWorkspaceLinkLabel: String,
        canShowInFinder: Bool
    ) {
        self.targetIds = targetIds
        self.isMulti = isMulti
        self.pinLabel = pinLabel
        self.pinEnabled = pinEnabled
        self.groups = groups
        self.eligibleGroupTargetIds = eligibleGroupTargetIds
        self.allTargetsInSameGroupId = allTargetsInSameGroupId
        self.hasAnyGroupedTarget = hasAnyGroupedTarget
        self.groupSelectedShortcutKey = groupSelectedShortcutKey
        self.groupSelectedShortcutModifiers = groupSelectedShortcutModifiers
        self.renameShortcutKey = renameShortcutKey
        self.renameShortcutModifiers = renameShortcutModifiers
        self.hasCustomTitle = hasCustomTitle
        self.editDescriptionShortcutKey = editDescriptionShortcutKey
        self.editDescriptionShortcutModifiers = editDescriptionShortcutModifiers
        self.hasCustomDescription = hasCustomDescription
        self.hasRemoteContextMenuTargets = hasRemoteContextMenuTargets
        self.reconnectLabel = reconnectLabel
        self.disconnectLabel = disconnectLabel
        self.allRemoteTargetsConnecting = allRemoteTargetsConnecting
        self.allRemoteTargetsDisconnected = allRemoteTargetsDisconnected
        self.hasCustomColor = hasCustomColor
        self.colorPalette = colorPalette
        self.copyableSidebarSSHError = copyableSidebarSSHError
        self.isFirstRow = isFirstRow
        self.isLastRow = isLastRow
        self.windowMoveTargets = windowMoveTargets
        self.closeShortcutKey = closeShortcutKey
        self.closeShortcutModifiers = closeShortcutModifiers
        self.closeLabel = closeLabel
        self.closeOthersDisabled = closeOthersDisabled
        self.markReadLabel = markReadLabel
        self.markUnreadLabel = markUnreadLabel
        self.clearLatestNotificationLabel = clearLatestNotificationLabel
        self.canMarkRead = canMarkRead
        self.canMarkUnread = canMarkUnread
        self.hasLatestNotifications = hasLatestNotifications
        self.workspaceNotifications = workspaceNotifications
        self.copyWorkspaceIDLabel = copyWorkspaceIDLabel
        self.copyWorkspaceLinkLabel = copyWorkspaceLinkLabel
        self.canShowInFinder = canShowInFinder
    }
}

public struct SidebarWorkspaceNotificationMenuItem: Identifiable, Sendable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}
