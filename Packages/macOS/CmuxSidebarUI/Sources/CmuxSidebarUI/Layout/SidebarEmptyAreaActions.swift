public import Foundation

/// Closure bundle exposing the app-target side effects ``SidebarEmptyArea``
/// triggers on a double-tap (spawning a workspace and re-syncing the sidebar
/// selection), so the view stays in `CmuxSidebarUI` without importing the
/// app-target `TabManager`/`AppDelegate`.
///
/// The app constructs this with `@MainActor` closures bound to the hovered
/// window's `TabManager` plus `AppDelegate.shared` new-workspace routing.
@MainActor
public struct SidebarEmptyAreaActions {
    /// Whether the selected workspace is a remote-tmux mirror. When true, a new
    /// workspace is spawned through ``performNewWorkspaceAction`` so it becomes a
    /// new tmux session instead of a local (orphan) workspace.
    public let selectedTabIsRemoteTmuxMirror: () -> Bool

    /// Spawns a new workspace through the remote-tmux-aware new-workspace action.
    public let performNewWorkspaceAction: () -> Void

    /// Appends a new local workspace at the end of the sidebar.
    public let addWorkspaceAtEnd: () -> Void

    /// The currently selected workspace id.
    public let selectedTabId: () -> UUID?

    /// The index of a workspace id in the live sidebar order.
    public let tabIndex: (UUID) -> Int?

    /// Switches the sidebar selection mode to the workspace-tabs list.
    public let selectTabs: () -> Void

    /// Creates the empty-area action bundle.
    public init(
        selectedTabIsRemoteTmuxMirror: @escaping () -> Bool,
        performNewWorkspaceAction: @escaping () -> Void,
        addWorkspaceAtEnd: @escaping () -> Void,
        selectedTabId: @escaping () -> UUID?,
        tabIndex: @escaping (UUID) -> Int?,
        selectTabs: @escaping () -> Void
    ) {
        self.selectedTabIsRemoteTmuxMirror = selectedTabIsRemoteTmuxMirror
        self.performNewWorkspaceAction = performNewWorkspaceAction
        self.addWorkspaceAtEnd = addWorkspaceAtEnd
        self.selectedTabId = selectedTabId
        self.tabIndex = tabIndex
        self.selectTabs = selectTabs
    }
}
