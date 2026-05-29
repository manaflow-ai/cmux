import Foundation

/// Protocol for receiving callbacks about workspace surface and pane layout events.
@MainActor
public protocol WorkspaceLayoutDelegate: AnyObject {
    // MARK: - Surface Lifecycle (Veto Operations)

    /// Called when a new surface is about to be created.
    /// Return `false` to prevent creation.
    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldCreateSurface surface: SurfaceTab, inPane pane: PaneID) -> Bool

    /// Called when a surface is about to be closed.
    /// Return `false` to prevent closing.
    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldCloseSurface surface: SurfaceTab, inPane pane: PaneID) -> Bool

    // MARK: - Surface Lifecycle (Notifications)

    /// Called after a surface has been created.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didCreateSurface surface: SurfaceTab, inPane pane: PaneID)

    /// Called after a surface has been closed.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didCloseSurface surfaceId: SurfaceID, fromPane pane: PaneID)

    /// Called when a surface is selected.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didSelectSurface surface: SurfaceTab, inPane pane: PaneID)

    /// Called when a surface is moved between panes.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didMoveSurface surface: SurfaceTab, fromPane source: PaneID, toPane destination: PaneID)

    // MARK: - Pane Lifecycle (Veto Operations)

    /// Called when a split is about to be created.
    /// Return `false` to prevent the split.
    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldSplitPane pane: PaneID, orientation: LayoutOrientation) -> Bool

    /// Called when a pane is about to be closed.
    /// Return `false` to prevent closing.
    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldClosePane pane: PaneID) -> Bool

    // MARK: - Pane Lifecycle (Notifications)

    /// Called after a split has been created.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: LayoutOrientation)

    /// Called after a pane has been closed.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didClosePane paneId: PaneID)

    /// Called when focus changes to a different pane.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didFocusPane pane: PaneID)

    // MARK: - Surface Requests

    /// Called when the user requests a new surface in a pane.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didRequestNewSurface kind: String, inPane pane: PaneID)

    /// Called when the user clicks a host-defined action in the layout chrome.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didRequestCustomAction identifier: String, inPane pane: PaneID)

    /// Called when the user triggers an action from a surface's context menu.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didRequestSurfaceContextAction action: SurfaceContextAction, for surface: SurfaceTab, inPane pane: PaneID)

    /// Called when the user chooses a host-provided destination from the surface move submenu.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didRequestSurfaceMoveToDestination destinationId: String, for surface: SurfaceTab, inPane pane: PaneID)

    // MARK: - Geometry

    /// Called when any pane geometry changes.
    func workspaceLayout(_ controller: WorkspaceLayoutController, didChangeGeometry snapshot: PaneLayoutSnapshot)

    /// Called to check if geometry notifications should be sent during divider drag.
    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldNotifyDuringDrag: Bool) -> Bool

    // MARK: - Legacy Tab Compatibility

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
    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldCreateSurface surface: SurfaceTab, inPane pane: PaneID) -> Bool {
        splitTabBar(controller, shouldCreateTab: surface, inPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldCloseSurface surface: SurfaceTab, inPane pane: PaneID) -> Bool {
        splitTabBar(controller, shouldCloseTab: surface, inPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didCreateSurface surface: SurfaceTab, inPane pane: PaneID) {
        splitTabBar(controller, didCreateTab: surface, inPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didCloseSurface surfaceId: SurfaceID, fromPane pane: PaneID) {
        splitTabBar(controller, didCloseTab: surfaceId, fromPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didSelectSurface surface: SurfaceTab, inPane pane: PaneID) {
        splitTabBar(controller, didSelectTab: surface, inPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didMoveSurface surface: SurfaceTab, fromPane source: PaneID, toPane destination: PaneID) {
        splitTabBar(controller, didMoveTab: surface, fromPane: source, toPane: destination)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldSplitPane pane: PaneID, orientation: LayoutOrientation) -> Bool {
        splitTabBar(controller, shouldSplitPane: pane, orientation: orientation)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldClosePane pane: PaneID) -> Bool {
        splitTabBar(controller, shouldClosePane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: LayoutOrientation) {
        splitTabBar(controller, didSplitPane: originalPane, newPane: newPane, orientation: orientation)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didClosePane paneId: PaneID) {
        splitTabBar(controller, didClosePane: paneId)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didFocusPane pane: PaneID) {
        splitTabBar(controller, didFocusPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didRequestNewSurface kind: String, inPane pane: PaneID) {
        splitTabBar(controller, didRequestNewTab: kind, inPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didRequestCustomAction identifier: String, inPane pane: PaneID) {
        splitTabBar(controller, didRequestCustomAction: identifier, inPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didRequestSurfaceContextAction action: SurfaceContextAction, for surface: SurfaceTab, inPane pane: PaneID) {
        splitTabBar(controller, didRequestSurfaceContextAction: action, for: surface, inPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didRequestSurfaceMoveToDestination destinationId: String, for surface: SurfaceTab, inPane pane: PaneID) {
        splitTabBar(controller, didRequestTabMoveToDestination: destinationId, for: surface, inPane: pane)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, didChangeGeometry snapshot: PaneLayoutSnapshot) {
        splitTabBar(controller, didChangeGeometry: snapshot)
    }

    func workspaceLayout(_ controller: WorkspaceLayoutController, shouldNotifyDuringDrag: Bool) -> Bool {
        splitTabBar(controller, shouldNotifyDuringDrag: shouldNotifyDuringDrag)
    }

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
