import AppKit
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

        // Destination window mirrors the live foreign session, then resets its
        // own presentation.
        let destination = SidebarDragState(workspaceDragRegistry: registry)
        #expect(destination.mirrorDragging(tabId: id))
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

    @Test func liveSessionCheckUsesTheInjectedPasteboard() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("sidebar-live-session-(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let registry = SidebarWorkspaceDragRegistry(
            dragPasteboardProvider: { pasteboard }
        )
        let state = SidebarDragState(workspaceDragRegistry: registry)
        let session = state.beginDragging(tabId: UUID())
        let type = NSPasteboard.PasteboardType(
            SidebarWorkspaceDragSession.pasteboardTypeIdentifier
        )

        #expect(!state.acceptsLiveSidebarSessionForCurrentPasteboard {
            pasteboard
        })
        #expect(pasteboard.setString(session.pasteboardValue, forType: type))
        #expect(state.acceptsLiveSidebarSessionForCurrentPasteboard {
            pasteboard
        })

        registry.nativeDraggingSessionDidEnd(
            sessionId: session.id,
            capabilityValue: session.pasteboardValue
        )
        pasteboard.clearContents()
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

    @Test func presentationDismissalKeepsNativeSessionAcrossReconstruction() throws {
        let registry = SidebarWorkspaceDragRegistry()
        let source = SidebarDragState(workspaceDragRegistry: registry)
        let workspaceId = UUID()
        let session = source.beginDragging(tabId: workspaceId)

        source.dismissPresentation()

        // A later generic clear belongs to the retired presentation, not to
        // AppKit's still-live native source.
        source.clearDrag()

        #expect(source.draggedTabId == nil)
        #expect(registry.currentWorkspaceId == workspaceId)

        let rebuilt = SidebarDragState(workspaceDragRegistry: registry)
        #expect(rebuilt.mirrorDragging(tabId: workspaceId))
        registry.nativeDraggingSessionDidEnd(
            sessionId: session.id,
            capabilityValue: session.pasteboardValue
        )
        #expect(rebuilt.draggedTabId == nil)
        #expect(source.draggedTabId == nil)
    }

    @Test func completedSessionRemainsEligibleUntilANewerDragStarts() {
        let registry = SidebarWorkspaceDragRegistry()
        let state = SidebarDragState(workspaceDragRegistry: registry)
        let workspaceId = UUID()
        let session = state.beginDragging(tabId: workspaceId)

        registry.nativeDraggingSessionDidEnd(
            sessionId: session.id,
            capabilityValue: session.pasteboardValue
        )

        #expect(
            state.acceptsWorkspaceDragSession(
                sessionId: session.id,
                workspaceId: workspaceId
            )
        )

        let newer = registry.beginSession(workspaceId: UUID())
        #expect(
            !state.acceptsWorkspaceDragSession(
                sessionId: session.id,
                workspaceId: workspaceId
            )
        )
        registry.nativeDraggingSessionDidEnd(
            sessionId: newer.id,
            capabilityValue: newer.pasteboardValue
        )
    }

    @Test func staleNativeCompletionCannotEndNewerSession() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("sidebar-drag-lifecycle-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let registry = SidebarWorkspaceDragRegistry(
            dragPasteboardProvider: { pasteboard }
        )
        let first = registry.beginSession(workspaceId: UUID())
        let second = registry.beginSession(workspaceId: UUID())
        pasteboard.setString(
            second.pasteboardValue,
            forType: NSPasteboard.PasteboardType(
                SidebarWorkspaceDragSession.pasteboardTypeIdentifier
            )
        )

        registry.nativeDraggingSessionDidEnd(
            sessionId: first.id,
            capabilityValue: first.pasteboardValue
        )

        #expect(registry.currentSession == second)
        #expect(
            pasteboard.string(
                forType: NSPasteboard.PasteboardType(
                    SidebarWorkspaceDragSession.pasteboardTypeIdentifier
                )
        ) == second.pasteboardValue
        )
    }

    @Test func mostRecentSessionTokenSurvivesCompletionForGenerationFencing() {
        let registry = SidebarWorkspaceDragRegistry()
        let first = registry.beginSession(workspaceId: UUID())
        registry.end(sessionId: first.id)

        let second = registry.beginSession(workspaceId: UUID())
        registry.end(sessionId: second.id)

        #expect(registry.currentSessionId == nil)
        #expect(registry.mostRecentSessionId == second.id)
        #expect(registry.mostRecentSessionId != first.id)
        #expect(registry.mostRecentWorkspaceId == second.workspaceId)
    }

    @Test func tokenizedPayloadRoundTripsWorkspaceAndSessionIdentity() {
        let session = SidebarWorkspaceDragSession(workspaceId: UUID())

        #expect(
            SidebarWorkspaceDragPayloadParser().workspaceId(from: session.pasteboardValue)
                == session.workspaceId
        )
        #expect(
            SidebarWorkspaceDragPayloadParser().sessionId(from: session.pasteboardValue)
                == session.id
        )
        #expect(
            SidebarWorkspaceDragPayloadParser().workspaceId(
                from: "\(SidebarWorkspaceDragSession.pasteboardPrefix)\(session.workspaceId.uuidString)"
            ) == session.workspaceId
        )
    }
}
