import Foundation
import Testing
import CmuxFoundation
@testable import CmuxSidebar

/// In-memory fake of the cross-window registry seam that records the calls the
/// coordinator makes, so tests assert the begin/end protocol without a real
/// process-wide instance.
@MainActor
private final class FakeWorkspaceDragRegistry: SidebarWorkspaceDragRegistering {
    var current: UUID?
    private(set) var beginCalls: [UUID] = []
    private(set) var endCalls: [UUID] = []

    var currentWorkspaceId: UUID? { current }

    func begin(workspaceId: UUID) {
        beginCalls.append(workspaceId)
        current = workspaceId
    }

    func end(workspaceId: UUID) {
        endCalls.append(workspaceId)
        if current == workspaceId { current = nil }
    }
}

@MainActor
@Suite struct SidebarDragStateTests {
    @Test func beginDraggingSetsLocalAndProcessWideIdentity() {
        let registry = FakeWorkspaceDragRegistry()
        let state = SidebarDragState(workspaceDragRegistry: registry)
        let id = UUID()

        state.setDropIndicator(SidebarDropIndicator(tabId: UUID(), edge: .bottom))
        state.beginDragging(tabId: id)

        #expect(state.draggedTabId == id)
        #expect(registry.beginCalls == [id])
        #expect(registry.current == id)
        // Begin clears any stale indicator.
        #expect(state.dropIndicator == nil)
    }

    @Test func clearDragEndsRegistryOnlyForOriginatingWindow() {
        let registry = FakeWorkspaceDragRegistry()
        let origin = SidebarDragState(workspaceDragRegistry: registry)
        let id = UUID()
        origin.beginDragging(tabId: id)

        origin.clearDrag()

        #expect(origin.draggedTabId == nil)
        #expect(registry.endCalls == [id])
        #expect(registry.current == nil)
    }

    @Test func mirroredForeignDragDoesNotEndRegistryOnClear() {
        let registry = FakeWorkspaceDragRegistry()
        // Originating window starts a drag.
        let origin = SidebarDragState(workspaceDragRegistry: registry)
        let id = UUID()
        origin.beginDragging(tabId: id)

        // Destination window mirrors the foreign id directly (no beginDragging),
        // then resets its own state.
        let destination = SidebarDragState(workspaceDragRegistry: registry)
        destination.draggedTabId = id
        destination.foreignDraggedIsPinned = true
        destination.clearDrag()

        // Destination cleared its local state but must not end the originating
        // window's registry entry.
        #expect(destination.draggedTabId == nil)
        #expect(destination.foreignDraggedIsPinned == nil)
        #expect(registry.endCalls.isEmpty)
        #expect(registry.current == id)
    }

    @Test func setDropIndicatorTracksTopLevelFlag() {
        let registry = FakeWorkspaceDragRegistry()
        let state = SidebarDragState(workspaceDragRegistry: registry)

        state.setDropIndicator(SidebarDropIndicator(tabId: nil, edge: .top), usesTopLevelRows: true)
        #expect(state.dropIndicatorUsesTopLevelRows == true)

        // A nil indicator never claims top-level positioning.
        state.setDropIndicator(nil, usesTopLevelRows: true)
        #expect(state.dropIndicator == nil)
        #expect(state.dropIndicatorUsesTopLevelRows == false)
    }

    @Test func currentWorkspaceDragIdReadsThroughRegistry() {
        let registry = FakeWorkspaceDragRegistry()
        let state = SidebarDragState(workspaceDragRegistry: registry)
        #expect(state.currentWorkspaceDragId == nil)

        let id = UUID()
        registry.current = id
        #expect(state.currentWorkspaceDragId == id)
    }
}

@MainActor
@Suite struct SidebarWorkspaceDragRegistryTests {
    @Test func endIgnoresStaleClearFromSupersededDrag() {
        let registry = SidebarWorkspaceDragRegistry()
        let first = UUID()
        let second = UUID()

        registry.begin(workspaceId: first)
        registry.begin(workspaceId: second)
        // A late clear from the superseded first drag is a no-op.
        registry.end(workspaceId: first)
        #expect(registry.currentWorkspaceId == second)

        registry.end(workspaceId: second)
        #expect(registry.currentWorkspaceId == nil)
    }
}
