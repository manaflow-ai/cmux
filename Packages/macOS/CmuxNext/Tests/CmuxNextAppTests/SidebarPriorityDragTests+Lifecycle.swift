import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

extension SidebarPriorityDragTests {
    enum LostPointer: CaseIterable {
        case appFocus, windowFocus, nextPress, otherWindowRelease, detach, panelDetach
    }

    @Test(arguments: LostPointer.allCases, [false, true])
    func lostPointerCancelsPriorityAndReattachmentCannotReviveIt(reason: LostPointer, dragging: Bool) async throws {
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        let harness = Harness(sidebar: sidebar)
        defer { harness.close() }
        let row = try #require(harness.panel.rows["c"])
        let originalFrame = row.frame
        let offset = dragging ? -row.frame.height : 3
        row.mouseDown(with: try harness.event(.leftMouseDown, on: "c"))
        row.mouseDragged(with: try harness.event(.leftMouseDragged, on: "c", dy: offset))
        #expect(harness.panel.draggingID == (dragging ? "c" : nil))
        #expect(row.layer?.zPosition == (dragging ? 1 : 0))
        sidebar.list.leftButtonIsDown = { false }

        switch reason {
        case .appFocus:
            // App resignation cancels even while the button is still physically held.
            sidebar.list.leftButtonIsDown = { true }
            // global-notice-allow: exercise the installed AppKit focus observers; this suite is serialized and closes its windows.
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        case .windowFocus:
            // global-notice-allow: exercise the installed AppKit focus observers; this suite is serialized and closes its windows.
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: harness.window)
        case .nextPress, .otherWindowRelease:
            let other = NSWindow(contentRect: NSRect(x: 400, y: 100, width: 100, height: 100),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            let type: NSEvent.EventType = reason == .nextPress ? .leftMouseDown : .leftMouseUp
            let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10),
                                                       modifierFlags: [], timestamp: 0, windowNumber: other.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            NSApplication.shared.sendEvent(event)
            // A release may be forwarded by an overlay; cancellation must wait for dispatch to finish.
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        case .detach:
            harness.window.contentView = nil
            harness.window.contentView = sidebar
        case .panelDetach:
            harness.panel.removeFromSuperview()
            sidebar.addSubview(harness.panel)
        }

        if reason == .appFocus, dragging {
            let bitmap = try #require(harness.panel.bitmapImageRepForCachingDisplay(in: harness.panel.bounds))
            harness.panel.cacheDisplay(in: harness.panel.bounds, to: bitmap)
            let image = try #require(bitmap.representation(using: .png, properties: [:]))
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: ".build/priority-lifecycle.png")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.write(to: output)
        }
        #expect(harness.panel.draggingID == nil)
        #expect(row.layer?.zPosition == 0)
        #expect(row.frame == originalFrame)
        // Deliver both a stale move and release: neither may revive the gesture or open the chat.
        row.mouseDragged(with: try harness.event(.leftMouseDragged, on: "c", dy: offset))
        row.mouseUp(with: try harness.event(.leftMouseUp, on: "c", dy: offset))
        #expect(harness.actions.isEmpty)
        #expect(harness.panel.panel.entries.map(\.id) == Self.entries.map(\.id))
        #expect(row.layer?.zPosition == 0)
        try harness.press("c", moves: [3])
        #expect(harness.actions == [.open("c")], "a fresh click works after lifecycle cancellation")
    }

    @Test(arguments: [false, true])
    func childKeyFocusKeepsHeldPriorityGestureAndForwardedReleaseCompletes(dragging: Bool) async throws {
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        let harness = Harness(sidebar: sidebar)
        defer { harness.close() }
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        harness.window.addChildWindow(child, ordered: .above)
        defer {
            harness.window.removeChildWindow(child)
            child.close()
        }
        let row = try #require(harness.panel.rows["c"])
        let offset = dragging ? -row.frame.height : 3
        row.mouseDown(with: try harness.event(.leftMouseDown, on: "c"))
        sidebar.list.leftButtonIsDown = { true }
        // global-notice-allow: verify the actual window observer preserves a held gesture; the suite owns this window.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: harness.window)
        row.mouseDragged(with: try harness.event(.leftMouseDragged, on: "c", dy: offset))
        #expect(harness.panel.draggingID == (dragging ? "c" : nil))
        sidebar.list.leftButtonIsDown = { false }
        // The monitor sees the child-window release before the overlay forwards it to the row.
        sidebar.list.pointerEventSeen(.leftMouseUp, in: child)
        row.mouseUp(with: try harness.event(.leftMouseUp, on: "c", dy: offset))
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(harness.actions == (dragging ? [.place("c", order: ["a", "c", "b"])] : [.open("c")]))
        #expect(harness.panel.draggingID == nil)
        #expect(row.layer?.zPosition == 0)
    }
}
