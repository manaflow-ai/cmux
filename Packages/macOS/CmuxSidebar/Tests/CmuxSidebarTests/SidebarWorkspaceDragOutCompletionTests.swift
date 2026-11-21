import AppKit
import Testing
@testable import CmuxSidebar

@MainActor
@Suite struct SidebarWorkspaceDragOutCompletionTests {
    @Test func completionUsesLiveCapabilityExactlyOnceAfterCleanup() {
        let board = NSPasteboard(name: .init("drag-out-test-\(UUID())"))
        let registry = SidebarWorkspaceDragRegistry(dragPasteboardProvider: { board })
        let session = registry.beginSession(workspaceId: UUID())
        var completed: [UUID] = []
        registry.onUnhandledNativeDragEnd = { received, point, operation, beganAt in
            completed.append(received.workspaceId)
            #expect(registry.currentSessionId == nil)
            #expect(point == NSPoint(x: -200, y: 50))
            #expect(operation.isEmpty)
            #expect(beganAt == 123)
        }
        for _ in 0..<2 {
            registry.completeNativeDrag(sessionId: session.id, capabilityValue: session.pasteboardValue,
                                        point: NSPoint(x: -200, y: 50), operation: [], beganAt: 123)
        }
        #expect(completed == [session.workspaceId])
    }

    @Test func forgedAndStaleCapabilitiesCannotMoveWorkspaces() {
        let board = NSPasteboard(name: .init("drag-out-test-\(UUID())"))
        let registry = SidebarWorkspaceDragRegistry(dragPasteboardProvider: { board })
        let old = registry.beginSession(workspaceId: UUID())
        let current = registry.beginSession(workspaceId: UUID())
        var count = 0
        registry.onUnhandledNativeDragEnd = { _, _, _, _ in count += 1 }
        registry.completeNativeDrag(sessionId: old.id, capabilityValue: old.pasteboardValue,
                                    point: .zero, operation: [], beganAt: 123)
        registry.completeNativeDrag(sessionId: current.id, capabilityValue: old.pasteboardValue,
                                    point: .zero, operation: [], beganAt: 123)
        #expect(count == 0)
        #expect(registry.currentSessionId == current.id)
    }
}
