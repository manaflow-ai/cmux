import AppKit
import Foundation
import Testing
import CmuxFoundation
@testable import CmuxSidebar

@MainActor
@Suite struct SidebarDragStateTests {
    @Test func beginDraggingSetsLocalAndProcessWideIdentity() {
        let registry = SidebarWorkspaceDragRegistry()
        let state = SidebarDragState(workspaceDragRegistry: registry)
        let id = UUID()
        state.setDropIndicator(SidebarDropIndicator(tabId: UUID(), edge: .bottom))
        state.beginDragging(tabId: id)

        #expect(state.draggedTabId == id)
        #expect(registry.currentWorkspaceId == id)
        // Begin clears any stale indicator.
        #expect(state.dropIndicator == nil)
    }

    @Test func clearDragEndsRegistryOnlyForOriginatingWindow() {
        let registry = SidebarWorkspaceDragRegistry()
        let origin = SidebarDragState(workspaceDragRegistry: registry)
        let id = UUID()
        origin.beginDragging(tabId: id)

        origin.clearDrag()

        #expect(origin.draggedTabId == nil)
        #expect(registry.currentWorkspaceId == nil)
    }

    @Test func mirroredForeignDragDoesNotEndRegistryOnClear() {
        let registry = SidebarWorkspaceDragRegistry()
        // Originating window starts a drag.
        let origin = SidebarDragState(workspaceDragRegistry: registry)
        let id = UUID()
        origin.beginDragging(tabId: id)

        // Destination window mirrors the source session, then resets only its
        // own presentation state.
        let destination = SidebarDragState(workspaceDragRegistry: registry)
        #expect(destination.mirrorDragging(tabId: id))
        destination.foreignDraggedIsPinned = true
        destination.clearDrag()

        // Destination cleared its local state but must not end the originating
        // window's registry entry.
        #expect(destination.draggedTabId == nil)
        #expect(destination.foreignDraggedIsPinned == nil)
        #expect(registry.currentWorkspaceId == id)
    }

    @Test func activatingCurrentSourceDoesNotDowngradeOwnership() {
        let registry = SidebarWorkspaceDragRegistry()
        let source = SidebarDragState(workspaceDragRegistry: registry)
        let id = UUID()
        source.beginDragging(tabId: id)

        source.activateDragging(tabId: id)
        source.clearDrag()

        #expect(
            registry.currentWorkspaceId == nil,
            "Re-observing a source session must not turn it into a mirror that cannot end the coordinator session."
        )
    }

    @Test func activationCannotResurrectSessionWithoutLiveSource() {
        let registry = SidebarWorkspaceDragRegistry()
        let state = SidebarDragState(workspaceDragRegistry: registry)
        let stalePasteboardWorkspaceId = UUID()

        #expect(!state.activateDragging(tabId: stalePasteboardWorkspaceId))
        #expect(state.draggedTabId == nil)
        #expect(registry.currentWorkspaceId == nil)
    }

    @Test func setDropIndicatorTracksTopLevelFlag() {
        let registry = SidebarWorkspaceDragRegistry()
        let state = SidebarDragState(workspaceDragRegistry: registry)

        state.setDropIndicator(SidebarDropIndicator(tabId: nil, edge: .top), usesTopLevelRows: true)
        #expect(state.dropIndicatorUsesTopLevelRows == true)

        // A nil indicator never claims top-level positioning.
        state.setDropIndicator(nil, usesTopLevelRows: true)
        #expect(state.dropIndicator == nil)
        #expect(state.dropIndicatorUsesTopLevelRows == false)
    }

    @Test func currentWorkspaceDragIdReadsThroughRegistry() {
        let registry = SidebarWorkspaceDragRegistry()
        let state = SidebarDragState(workspaceDragRegistry: registry)
        #expect(state.currentWorkspaceDragId == nil)

        let id = UUID()
        registry.begin(workspaceId: id)
        #expect(state.currentWorkspaceDragId == id)
    }
}

@MainActor
@Suite struct SidebarWorkspaceDragRegistryTests {
    @Test func endIgnoresStaleClearFromSupersededDrag() {
        let registry = SidebarWorkspaceDragRegistry()
        let first = UUID()
        let second = UUID()

        let firstSession = registry.begin(workspaceId: first)
        let secondSession = registry.begin(workspaceId: second)
        // A late clear from the superseded first drag is a no-op.
        registry.end(sessionId: firstSession.id)
        #expect(registry.currentWorkspaceId == second)

        registry.end(sessionId: secondSession.id)
        #expect(registry.currentWorkspaceId == nil)
    }

    @Test func appResignDoesNotPreemptActiveWorkspaceDragSourceLifecycle() {
        let registry = SidebarWorkspaceDragRegistry()
        let workspaceId = UUID()
        let source = SidebarDragState(workspaceDragRegistry: registry)
        let destination = SidebarDragState(workspaceDragRegistry: registry)

        source.beginDragging(tabId: workspaceId)
        #expect(destination.mirrorDragging(tabId: workspaceId))
        #expect(registry.currentWorkspaceId == workspaceId)

        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        #expect(
            registry.currentWorkspaceId == workspaceId,
            "App deactivation can happen while a native drag is crossing windows or applications; only the drag source lifecycle may end its identity."
        )
        #expect(source.draggedTabId == workspaceId)
        #expect(destination.draggedTabId == workspaceId)

        source.finishDrag()
    }

    @Test func nativeSourceEndClearsEveryMatchingPresentation() throws {
        let registry = SidebarWorkspaceDragRegistry()
        let workspaceId = UUID()
        let source = SidebarDragState(workspaceDragRegistry: registry)
        let destination = SidebarDragState(workspaceDragRegistry: registry)

        source.beginDragging(tabId: workspaceId)
        #expect(destination.mirrorDragging(tabId: workspaceId))
        let sessionId = try #require(registry.currentSession?.id)
        registry.nativeDraggingSessionDidEnd(sessionId: sessionId)

        #expect(registry.currentWorkspaceId == nil)
        #expect(source.draggedTabId == nil)
        #expect(destination.draggedTabId == nil)
    }

    @Test func sourcePresentationCanRebuildWithoutLosingSessionOwnership() {
        let registry = SidebarWorkspaceDragRegistry()
        let workspaceId = UUID()
        let source = SidebarDragState(workspaceDragRegistry: registry)
        let destination = SidebarDragState(workspaceDragRegistry: registry)

        source.beginDragging(tabId: workspaceId)
        #expect(destination.mirrorDragging(tabId: workspaceId))

        source.dismissPresentation()
        #expect(source.draggedTabId == nil)
        #expect(registry.currentWorkspaceId == workspaceId)

        source.activateDragging(tabId: workspaceId)
        #expect(source.draggedTabId == workspaceId)

        source.clearDrag()
        #expect(registry.currentWorkspaceId == nil)
        #expect(destination.draggedTabId == nil)
    }
}
