import Bonsplit
import CmuxBrowser
import CmuxPanes
import Foundation

/// `Workspace`'s conformance to the `CmuxBrowser` ``BrowserOpenWorkspaceHandle``
/// seam: the per-workspace browser-panel creation operations the package
/// ``BrowserOpenCoordinator`` drives but cannot own, because `Workspace` is an
/// app-target god type owning the Bonsplit split tree and the WebKit
/// `BrowserPanel` instances.
///
/// Every member forwards to the exact `Workspace` member the legacy
/// `TabManager.openBrowser`/`newBrowserSplit`/`newBrowserSurface` bodies read
/// off the resolved workspace, mapping the created `BrowserPanel?` to its
/// `UUID?` id at this boundary so the package never sees the app-owned panel
/// reference.
extension Workspace: BrowserOpenWorkspaceHandle {
    func hasPanel(_ panelId: UUID) -> Bool {
        panels[panelId] != nil
    }

    func panelIdsSortedByUUIDString() -> [UUID] {
        panels.keys.sorted { $0.uuidString < $1.uuidString }
    }

    var focusedOrFirstPaneId: PaneID? {
        bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
    }

    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL?,
        focus: Bool,
        insertAtEnd: Bool,
        preferredProfileID: UUID?
    ) -> UUID? {
        newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: focus,
            insertAtEnd: insertAtEnd,
            preferredProfileID: preferredProfileID
        )?.id
    }

    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL?,
        preferredProfileID: UUID?
    ) -> UUID? {
        newBrowserSurface(
            inPane: paneId,
            url: url,
            preferredProfileID: preferredProfileID
        )?.id
    }

    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        url: URL?,
        preferredProfileID: UUID?,
        focus: Bool
    ) -> UUID? {
        newBrowserSplit(
            from: panelId,
            orientation: orientation,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: focus
        )?.id
    }

    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        url: URL?,
        preferredProfileID: UUID?,
        focus: Bool,
        initialDividerPosition: CGFloat?
    ) -> UUID? {
        newBrowserSplit(
            from: panelId,
            orientation: orientation,
            insertFirst: insertFirst,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: focus,
            initialDividerPosition: initialDividerPosition
        )?.id
    }
}
