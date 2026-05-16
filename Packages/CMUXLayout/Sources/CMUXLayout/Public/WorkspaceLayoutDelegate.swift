import Foundation

/// Protocol for receiving callbacks about tab bar events
@MainActor
public protocol WorkspaceLayoutDelegate: AnyObject {
    // MARK: - SurfaceTab Lifecycle (Veto Operations)

    /// Called when a new tab is about to be created.
    /// Return `false` to prevent creation.
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldCreateTab tab: SurfaceTab, inPane pane: PaneID) -> Bool

    /// Called when a tab is about to be closed.
    /// Return `false` to prevent closing (e.g., prompt to save unsaved changes).
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldCloseTab tab: SurfaceTab, inPane pane: PaneID) -> Bool

    // MARK: - SurfaceTab Lifecycle (Notifications)

    /// Called after a tab has been created.
    func splitTabBar(_ controller: WorkspaceLayoutController, didCreateTab tab: SurfaceTab, inPane pane: PaneID)

    /// Called after a tab has been closed.
    func splitTabBar(_ controller: WorkspaceLayoutController, didCloseTab tabId: SurfaceID, fromPane pane: PaneID)

    /// Called when a tab is selected.
    func splitTabBar(_ controller: WorkspaceLayoutController, didSelectTab tab: SurfaceTab, inPane pane: PaneID)

    /// Called when a tab is moved between panes.
    func splitTabBar(_ controller: WorkspaceLayoutController, didMoveTab tab: SurfaceTab, fromPane source: PaneID, toPane destination: PaneID)

    // MARK: - Split Lifecycle (Veto Operations)

    /// Called when a split is about to be created.
    /// Return `false` to prevent the split.
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldSplitPane pane: PaneID, orientation: LayoutOrientation) -> Bool

    /// Called when a pane is about to be closed.
    /// Return `false` to prevent closing.
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldClosePane pane: PaneID) -> Bool

    // MARK: - Split Lifecycle (Notifications)

    /// Called after a split has been created.
    func splitTabBar(_ controller: WorkspaceLayoutController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: LayoutOrientation)

    /// Called after a pane has been closed.
    func splitTabBar(_ controller: WorkspaceLayoutController, didClosePane paneId: PaneID)

    // MARK: - Focus

    /// Called when focus changes to a different pane.
    func splitTabBar(_ controller: WorkspaceLayoutController, didFocusPane pane: PaneID)

    // MARK: - New SurfaceTab Request

    /// Called when the user clicks a "new tab" action in the tab bar.
    /// The `kind` string identifies the type of tab (e.g. "terminal", "browser").
    func splitTabBar(_ controller: WorkspaceLayoutController, didRequestNewTab kind: String, inPane pane: PaneID)

    /// Called when the user clicks a host-defined action in the tab bar.
    func splitTabBar(_ controller: WorkspaceLayoutController, didRequestCustomAction identifier: String, inPane pane: PaneID)

    /// Called when the user triggers an action from a tab's context menu.
    func splitTabBar(_ controller: WorkspaceLayoutController, didRequestSurfaceContextAction action: SurfaceContextAction, for tab: SurfaceTab, inPane pane: PaneID)

    /// Called when the user chooses a host-provided destination from the tab move submenu.
    func splitTabBar(_ controller: WorkspaceLayoutController, didRequestTabMoveToDestination destinationId: String, for tab: SurfaceTab, inPane pane: PaneID)

    // MARK: - Geometry

    /// Called when any pane geometry changes (resize, split, close)
    func splitTabBar(_ controller: WorkspaceLayoutController, didChangeGeometry snapshot: PaneLayoutSnapshot)

    /// Called to check if notifications should be sent during divider drag (opt-in for real-time sync)
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldNotifyDuringDrag: Bool) -> Bool
}

// MARK: - Default Implementations (all methods optional)

public extension WorkspaceLayoutDelegate {
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldCreateTab tab: SurfaceTab, inPane pane: PaneID) -> Bool { true }
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldCloseTab tab: SurfaceTab, inPane pane: PaneID) -> Bool { true }
    func splitTabBar(_ controller: WorkspaceLayoutController, didCreateTab tab: SurfaceTab, inPane pane: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didCloseTab tabId: SurfaceID, fromPane pane: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didSelectTab tab: SurfaceTab, inPane pane: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didMoveTab tab: SurfaceTab, fromPane source: PaneID, toPane destination: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldSplitPane pane: PaneID, orientation: LayoutOrientation) -> Bool { true }
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldClosePane pane: PaneID) -> Bool { true }
    func splitTabBar(_ controller: WorkspaceLayoutController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: LayoutOrientation) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didClosePane paneId: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didFocusPane pane: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didRequestNewTab kind: String, inPane pane: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didRequestCustomAction identifier: String, inPane pane: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didRequestSurfaceContextAction action: SurfaceContextAction, for tab: SurfaceTab, inPane pane: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didRequestTabMoveToDestination destinationId: String, for tab: SurfaceTab, inPane pane: PaneID) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, didChangeGeometry snapshot: PaneLayoutSnapshot) {}
    func splitTabBar(_ controller: WorkspaceLayoutController, shouldNotifyDuringDrag: Bool) -> Bool { false }
}
