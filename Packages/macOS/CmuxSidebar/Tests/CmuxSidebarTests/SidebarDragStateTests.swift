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
        state.isSimulated = true

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
        origin.isSimulated = true
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
        origin.isSimulated = true
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
        source.isSimulated = true
        source.beginDragging(tabId: id)

        source.activateDragging(tabId: id)
        source.clearDrag()

        #expect(
            registry.currentWorkspaceId == nil,
            "Re-observing a source session must not turn it into a mirror that cannot end the coordinator session."
        )
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
        registry.begin(workspaceId: id, monitorLifecycle: false)
        #expect(state.currentWorkspaceDragId == id)
    }
}

@MainActor
@Suite struct SidebarWorkspaceDragRegistryTests {
    @Test func endIgnoresStaleClearFromSupersededDrag() {
        let registry = SidebarWorkspaceDragRegistry()
        let first = UUID()
        let second = UUID()

        let firstSession = registry.begin(workspaceId: first, monitorLifecycle: false)
        let secondSession = registry.begin(workspaceId: second, monitorLifecycle: false)
        // A late clear from the superseded first drag is a no-op.
        registry.end(sessionId: firstSession.id)
        #expect(registry.currentWorkspaceId == second)

        registry.end(sessionId: secondSession.id)
        #expect(registry.currentWorkspaceId == nil)
    }

    @Test func appResignClearsActiveWorkspaceDragSynchronously() {
        let registry = SidebarWorkspaceDragRegistry(isLeftMouseButtonPressed: { true })
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
            registry.currentWorkspaceId == nil,
            "A workspace drag must not leave stale process-wide identity after app deactivation."
        )
        #expect(source.draggedTabId == nil)
        #expect(destination.draggedTabId == nil)
    }
}
