import Foundation

/// Protocol for receiving callbacks about paper layout events.
/// Mirrors BonsplitDelegate's shape so Workspace can port method-by-method.
@MainActor
protocol PaperLayoutDelegate: AnyObject {
    // MARK: - Tab Lifecycle (Veto)
    func paperLayout(_ controller: PaperLayoutController, shouldCreateTab tab: PaperTab, inPane pane: PaneID) -> Bool
    func paperLayout(_ controller: PaperLayoutController, shouldCloseTab tab: PaperTab, inPane pane: PaneID) -> Bool

    // MARK: - Tab Lifecycle (Notifications)
    func paperLayout(_ controller: PaperLayoutController, didCreateTab tab: PaperTab, inPane pane: PaneID)
    func paperLayout(_ controller: PaperLayoutController, didCloseTab tabId: TabID, fromPane pane: PaneID)
    func paperLayout(_ controller: PaperLayoutController, didSelectTab tab: PaperTab, inPane pane: PaneID)
    func paperLayout(_ controller: PaperLayoutController, didMoveTab tab: PaperTab, fromPane source: PaneID, toPane destination: PaneID)

    // MARK: - Pane Lifecycle (Veto)
    func paperLayout(_ controller: PaperLayoutController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool
    func paperLayout(_ controller: PaperLayoutController, shouldClosePane pane: PaneID) -> Bool

    // MARK: - Pane Lifecycle (Notifications)
    func paperLayout(_ controller: PaperLayoutController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation)
    func paperLayout(_ controller: PaperLayoutController, didClosePane paneId: PaneID)

    // MARK: - Focus
    func paperLayout(_ controller: PaperLayoutController, didFocusPane pane: PaneID)

    // MARK: - Requests
    func paperLayout(_ controller: PaperLayoutController, didRequestNewTab kind: String, inPane pane: PaneID)
    func paperLayout(_ controller: PaperLayoutController, didRequestTabContextAction action: TabContextAction, for tab: PaperTab, inPane pane: PaneID)

    // MARK: - Geometry
    func paperLayout(_ controller: PaperLayoutController, didChangeGeometry snapshot: LayoutSnapshot)
    func paperLayout(_ controller: PaperLayoutController, shouldNotifyDuringDrag: Bool) -> Bool
}

// MARK: - Default Implementations (all methods optional)

extension PaperLayoutDelegate {
    func paperLayout(_ controller: PaperLayoutController, shouldCreateTab tab: PaperTab, inPane pane: PaneID) -> Bool { true }
    func paperLayout(_ controller: PaperLayoutController, shouldCloseTab tab: PaperTab, inPane pane: PaneID) -> Bool { true }
    func paperLayout(_ controller: PaperLayoutController, didCreateTab tab: PaperTab, inPane pane: PaneID) {}
    func paperLayout(_ controller: PaperLayoutController, didCloseTab tabId: TabID, fromPane pane: PaneID) {}
    func paperLayout(_ controller: PaperLayoutController, didSelectTab tab: PaperTab, inPane pane: PaneID) {}
    func paperLayout(_ controller: PaperLayoutController, didMoveTab tab: PaperTab, fromPane source: PaneID, toPane destination: PaneID) {}
    func paperLayout(_ controller: PaperLayoutController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool { true }
    func paperLayout(_ controller: PaperLayoutController, shouldClosePane pane: PaneID) -> Bool { true }
    func paperLayout(_ controller: PaperLayoutController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {}
    func paperLayout(_ controller: PaperLayoutController, didClosePane paneId: PaneID) {}
    func paperLayout(_ controller: PaperLayoutController, didFocusPane pane: PaneID) {}
    func paperLayout(_ controller: PaperLayoutController, didRequestNewTab kind: String, inPane pane: PaneID) {}
    func paperLayout(_ controller: PaperLayoutController, didRequestTabContextAction action: TabContextAction, for tab: PaperTab, inPane pane: PaneID) {}
    func paperLayout(_ controller: PaperLayoutController, didChangeGeometry snapshot: LayoutSnapshot) {}
    func paperLayout(_ controller: PaperLayoutController, shouldNotifyDuringDrag: Bool) -> Bool { false }
}
