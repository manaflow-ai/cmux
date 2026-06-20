public import Foundation

/// The fully-resolved render state for the workspace-command menu, computed by
/// ``WorkspaceCommandCoordinator/menuState()`` so the app-target
/// `@CommandsBuilder` body only places buttons and reads these flags.
///
/// Every `disabled(...)` predicate and dynamic label the legacy
/// `workspaceCommandMenuContent(manager:)` computed inline now lives on the
/// coordinator and arrives here as `Sendable` values. The menu TREE (the
/// `Button`/`Menu`/`Divider` SwiftUI shell and its `String(localized:)` labels)
/// must stay in the app target — a SwiftUI `@CommandsBuilder` cannot move into a
/// package — but no decision logic remains in it.
public struct WorkspaceCommandMenuState: Sendable, Equatable {
    /// Whether a workspace is selected at all. When `false` every
    /// selection-scoped item is disabled.
    public let hasSelectedWorkspace: Bool
    /// The selected workspace's index in the window's tab order, or `nil` when
    /// nothing is selected.
    public let selectedWorkspaceIndex: Int?
    /// The window's total workspace count (drives the move-down / close-below
    /// boundary checks).
    public let workspaceCount: Int
    /// Whether the selected workspace carries a user-set custom title (drives the
    /// "Remove Custom Workspace Name" item's presence).
    public let selectedWorkspaceHasCustomTitle: Bool
    /// The localized "Pin Workspace" / "Unpin Workspace" label for the toggle
    /// item, resolved app-side and carried through.
    public let pinToggleLabel: String
    /// Whether the pin toggle is enabled (legacy `pinState != nil`).
    public let pinToggleEnabled: Bool
    /// Whether the selected workspace can currently be marked read.
    public let canMarkRead: Bool
    /// Whether the selected workspace can currently be marked unread.
    public let canMarkUnread: Bool
    /// The "Move Workspace to Window" destination rows.
    public let windowMoveTargets: [WorkspaceCommandWindowTarget]

    /// Creates a resolved menu render state.
    public init(
        hasSelectedWorkspace: Bool,
        selectedWorkspaceIndex: Int?,
        workspaceCount: Int,
        selectedWorkspaceHasCustomTitle: Bool,
        pinToggleLabel: String,
        pinToggleEnabled: Bool,
        canMarkRead: Bool,
        canMarkUnread: Bool,
        windowMoveTargets: [WorkspaceCommandWindowTarget]
    ) {
        self.hasSelectedWorkspace = hasSelectedWorkspace
        self.selectedWorkspaceIndex = selectedWorkspaceIndex
        self.workspaceCount = workspaceCount
        self.selectedWorkspaceHasCustomTitle = selectedWorkspaceHasCustomTitle
        self.pinToggleLabel = pinToggleLabel
        self.pinToggleEnabled = pinToggleEnabled
        self.canMarkRead = canMarkRead
        self.canMarkUnread = canMarkUnread
        self.windowMoveTargets = windowMoveTargets
    }

    // MARK: - Derived menu-item enablement (legacy inline `disabled(...)`)

    /// "Move Up" enabled: a workspace is selected and not already at the top.
    public var canMoveUp: Bool {
        guard let index = selectedWorkspaceIndex else { return false }
        return index != 0
    }

    /// "Move Down" enabled: a workspace is selected and not already at the
    /// bottom.
    public var canMoveDown: Bool {
        guard let index = selectedWorkspaceIndex else { return false }
        return index != workspaceCount - 1
    }

    /// "Move to Top" enabled: a workspace is selected and not already at the
    /// top (legacy `workspace == nil || workspaceIndex == 0`).
    public var canMoveToTop: Bool {
        hasSelectedWorkspace && selectedWorkspaceIndex != 0
    }

    /// "Close Other Workspaces" enabled: a workspace is selected and more than
    /// one workspace exists.
    public var canCloseOthers: Bool {
        hasSelectedWorkspace && workspaceCount > 1
    }

    /// "Close Workspaces Below" enabled: same boundary as "Move Down".
    public var canCloseBelow: Bool { canMoveDown }

    /// "Close Workspaces Above" enabled: a workspace is selected and not at the
    /// top.
    public var canCloseAbove: Bool {
        guard let index = selectedWorkspaceIndex else { return false }
        return index != 0
    }
}
