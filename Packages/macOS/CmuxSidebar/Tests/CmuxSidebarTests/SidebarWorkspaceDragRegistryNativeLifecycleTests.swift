import AppKit
import CmuxFoundation
import Foundation
import Testing
@testable import CmuxSidebar

@MainActor
@Suite("Sidebar workspace native drag lifecycle", .serialized)
struct SidebarWorkspaceDragRegistryNativeLifecycleTests {
    @Test("A new session reclaims the previous native source and keeps its view owned until then")
    func newSessionReclaimsSupersededNativeSource() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("sidebar-native-lifecycle-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        var startedSource: SidebarWorkspaceDragSessionSource?
        var sequence = 0
        let registry = SidebarWorkspaceDragRegistry(
            dragPasteboardProvider: { pasteboard },
            nativeDragStarter: { _, _, _, source in
                sequence += 1
                startedSource = source as? SidebarWorkspaceDragSessionSource
                return TestDraggingSession(sequence: sequence, pasteboard: pasteboard)
            }
        )
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        var sourceView: NSView? = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        weak var weakSourceView: NSView?
        weakSourceView = sourceView
        let first = registry.beginSession(workspaceId: UUID())
        let firstItem = NSPasteboardItem()
        #expect(registry.beginNativeDragging(
            sessionId: first.id,
            pasteboardItem: firstItem,
            sourceView: sourceView!,
            event: event,
            draggingFrame: sourceView!.bounds,
            dragImage: NSImage(size: sourceView!.bounds.size),
            capabilityValue: first.pasteboardValue
        ))
        sourceView = nil
        #expect(weakSourceView != nil)
        #expect(registry.currentSessionId == first.id)

        let newerPayload = SidebarWorkspaceDragSession(workspaceId: UUID()).pasteboardValue
        #expect(
            pasteboard.setString(
                newerPayload,
                forType: NSPasteboard.PasteboardType(
                    SidebarWorkspaceDragSession.pasteboardTypeIdentifier
                )
            )
        )
        let second = registry.beginNativeSession(workspaceId: UUID())
        #expect(registry.currentSessionId == second.id)
        #expect(registry.currentWorkspaceId == second.workspaceId)
        #expect(weakSourceView == nil)
        #expect(startedSource != nil)
        #expect(
            pasteboard.string(
                forType: NSPasteboard.PasteboardType(
                    SidebarWorkspaceDragSession.pasteboardTypeIdentifier
                )
            ) == newerPayload
        )

        pasteboard.clearContents()
    }

    @Test("A logical begin does not reclaim a live native source")
    func logicalBeginPreservesLiveNativeSource() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("sidebar-native-logical-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        var startedSource: SidebarWorkspaceDragSessionSource?
        let registry = SidebarWorkspaceDragRegistry(
            dragPasteboardProvider: { pasteboard },
            nativeDragStarter: { _, _, _, source in
                startedSource = source as? SidebarWorkspaceDragSessionSource
                return TestDraggingSession(sequence: 1, pasteboard: pasteboard)
            }
        )
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        var sourceView: NSView? = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        weak var weakSourceView: NSView?
        weakSourceView = sourceView
        let first = registry.beginSession(workspaceId: UUID())
        #expect(registry.beginNativeDragging(
            sessionId: first.id,
            pasteboardItem: NSPasteboardItem(),
            sourceView: sourceView!,
            event: event,
            draggingFrame: sourceView!.bounds,
            dragImage: NSImage(size: sourceView!.bounds.size),
            capabilityValue: first.pasteboardValue
        ))
        sourceView = nil

        let second = registry.beginSession(workspaceId: UUID())

        #expect(startedSource != nil)
        #expect(registry.currentSessionId == second.id)
        #expect(weakSourceView != nil)

        registry.reclaimSupersededNativeSources(excludingSessionId: second.id)
        #expect(weakSourceView == nil)
        pasteboard.clearContents()
    }

    @Test("A pointer boundary does not reclaim an explicitly excluded source")
    func pointerBoundaryKeepsExcludedNativeSource() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("sidebar-native-exclusion-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        var startedSource: SidebarWorkspaceDragSessionSource?
        let registry = SidebarWorkspaceDragRegistry(
            dragPasteboardProvider: { pasteboard },
            nativeDragStarter: { _, _, _, source in
                startedSource = source as? SidebarWorkspaceDragSessionSource
                return TestDraggingSession(sequence: 1, pasteboard: pasteboard)
            }
        )
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let sourceView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        let session = registry.beginSession(workspaceId: UUID())
        #expect(registry.beginNativeDragging(
            sessionId: session.id,
            pasteboardItem: NSPasteboardItem(),
            sourceView: sourceView,
            event: event,
            draggingFrame: sourceView.bounds,
            dragImage: NSImage(size: sourceView.bounds.size),
            capabilityValue: session.pasteboardValue
        ))

        registry.reclaimSupersededNativeSources(excludingSessionId: session.id)

        #expect(startedSource != nil)
        #expect(registry.currentSessionId == session.id)
        #expect(pasteboard.string(forType: NSPasteboard.PasteboardType(
            SidebarWorkspaceDragSession.pasteboardTypeIdentifier
        )) == session.pasteboardValue)
        pasteboard.clearContents()
    }

    @MainActor
    private final class TestDraggingSession: NSDraggingSession {
        private let sequenceNumber: Int
        // The test double exposes an immutable pasteboard to AppKit's
        // nonisolated getter; no mutable state crosses that boundary.
        nonisolated(unsafe) private let sessionPasteboard: NSPasteboard

        init(sequence: Int, pasteboard: NSPasteboard) {
            sequenceNumber = sequence
            sessionPasteboard = pasteboard
            super.init()
        }

        override var draggingSequenceNumber: Int { sequenceNumber }
        nonisolated override var draggingPasteboard: NSPasteboard { sessionPasteboard }
    }
}
