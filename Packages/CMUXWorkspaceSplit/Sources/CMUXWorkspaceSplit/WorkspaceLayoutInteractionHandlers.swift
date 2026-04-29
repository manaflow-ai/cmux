import AppKit
import Foundation

@MainActor
struct WorkspaceLayoutInteractionHandlers {
    let notifyGeometryChangeHandler: (Bool) -> Void
    let setContainerFrameHandler: (CGRect) -> Void
    let setDividerPositionHandler: (CGFloat, UUID) -> Bool
    let consumeSplitEntryAnimationHandler: (UUID) -> Void
    let beginTabDragHandler: (TabID, PaneID) -> Void
    let clearDragStateHandler: () -> Void
    let focusPaneHandler: (PaneID) -> Bool
    let selectTabHandler: (TabID) -> Void
    let requestCloseTabHandler: (TabID, PaneID) -> Bool
    let togglePaneZoomHandler: (PaneID) -> Bool
    let requestTabContextActionHandler: (TabContextAction, TabID, PaneID) -> Void
    let requestNewTabHandler: (WorkspaceLayoutTabKind, PaneID) -> Void
    let splitPaneHandler: (PaneID?, SplitOrientation) -> PaneID?
    let splitPaneMovingTabHandler: (PaneID?, SplitOrientation, TabID, Bool, Bool) -> PaneID?
    let moveTabHandler: (TabID, PaneID, Int?) -> Bool
    let handleExternalTabDropHandler: (WorkspaceLayoutExternalTabDropRequest) -> Bool
    let handleFileDropHandler: ([URL], PaneID) -> Bool

    func notifyGeometryChange(isDragging: Bool) {
        notifyGeometryChangeHandler(isDragging)
    }

    func setContainerFrame(_ frame: CGRect) {
        setContainerFrameHandler(frame)
    }

    func setDividerPosition(_ position: CGFloat, forSplit splitId: UUID) -> Bool {
        setDividerPositionHandler(position, splitId)
    }

    func consumeSplitEntryAnimation(_ splitId: UUID) {
        consumeSplitEntryAnimationHandler(splitId)
    }

    func beginTabDrag(tabId: TabID, sourcePaneId: PaneID) {
        beginTabDragHandler(tabId, sourcePaneId)
    }

    func clearDragState() {
        clearDragStateHandler()
    }

    func focusPane(_ paneId: PaneID) -> Bool {
        focusPaneHandler(paneId)
    }

    func selectTab(_ tabId: TabID) {
        selectTabHandler(tabId)
    }

    func requestCloseTab(_ tabId: TabID, inPane paneId: PaneID) -> Bool {
        requestCloseTabHandler(tabId, paneId)
    }

    func togglePaneZoom(inPane paneId: PaneID) -> Bool {
        togglePaneZoomHandler(paneId)
    }

    func requestTabContextAction(_ action: TabContextAction, for tabId: TabID, inPane paneId: PaneID) {
        requestTabContextActionHandler(action, tabId, paneId)
    }

    func requestNewTab(kind: WorkspaceLayoutTabKind, inPane paneId: PaneID) {
        requestNewTabHandler(kind, paneId)
    }

    func splitPane(_ paneId: PaneID?, orientation: SplitOrientation) -> PaneID? {
        splitPaneHandler(paneId, orientation)
    }

    func splitPane(
        _ paneId: PaneID?,
        orientation: SplitOrientation,
        movingTab tabId: TabID,
        insertFirst: Bool,
        focusNewPane: Bool
    ) -> PaneID? {
        splitPaneMovingTabHandler(paneId, orientation, tabId, insertFirst, focusNewPane)
    }

    func moveTab(_ tabId: TabID, toPane paneId: PaneID, atIndex index: Int?) -> Bool {
        moveTabHandler(tabId, paneId, index)
    }

    func handleExternalTabDrop(_ request: WorkspaceLayoutExternalTabDropRequest) -> Bool {
        handleExternalTabDropHandler(request)
    }

    func handleFileDrop(_ urls: [URL], in paneId: PaneID) -> Bool {
        handleFileDropHandler(urls, paneId)
    }

    static let noop = WorkspaceLayoutInteractionHandlers(
        notifyGeometryChangeHandler: { _ in },
        setContainerFrameHandler: { _ in },
        setDividerPositionHandler: { _, _ in false },
        consumeSplitEntryAnimationHandler: { _ in },
        beginTabDragHandler: { _, _ in },
        clearDragStateHandler: {},
        focusPaneHandler: { _ in false },
        selectTabHandler: { _ in },
        requestCloseTabHandler: { _, _ in false },
        togglePaneZoomHandler: { _ in false },
        requestTabContextActionHandler: { _, _, _ in },
        requestNewTabHandler: { _, _ in },
        splitPaneHandler: { _, _ in nil },
        splitPaneMovingTabHandler: { _, _, _, _, _ in nil },
        moveTabHandler: { _, _, _ in false },
        handleExternalTabDropHandler: { _ in false },
        handleFileDropHandler: { _, _ in false }
    )
}

/// Main entry point for the WorkspaceLayout library.
