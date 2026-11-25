import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// A space another window shows keeps its window mark (the ring) while the dots move: the drag's dot snapshots draw
/// it as the bar does (#38281 review follow-up F1).
@MainActor @Suite(.serialized, .closesItsWindows) struct ProfileBarDotDragWindowMarkTests {
    static let keys = (0..<3).map { ProfileKey("space\($0)") }

    /// Starts a drag of the first dot in a fresh bar and answers the snapshot of the second space's dot.
    private func secondDotSnapshot(ringed: Bool) throws -> Data {
        let model = SidebarModel()
        model.profiles = Self.keys.enumerated().map { SidebarProfile(id: $1, name: "Space \($0)") }
        model.activeProfileID = Self.keys[0]
        let view = ProfileBarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        window.contentView = view
        view.switcherStyleOverride = .ring
        if ringed { view.windowMarks.elsewhere = [Self.keys[1]: SpaceElsewhere(windowID: "other", incognito: false)] }
        view.layoutSubtreeIfNeeded()
        view.refresh()
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let first = view.slotRects()[0]
        view.mouseDown(with: event(.leftMouseDown, NSPoint(x: first.midX, y: first.midY)))
        view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: first.midX + 12, y: first.midY)))
        let drag = try #require(view.dotDrag, "the press and move start a dot drag")
        let contents = try #require(drag.dots[1].contents as AnyObject?)
        #expect(CFGetTypeID(contents) == CGImage.typeID, "a dot snapshot is a rendered image")
        let bitmap = NSBitmapImageRep(cgImage: unsafeDowncast(contents, to: CGImage.self))
        view.mouseUp(with: event(.leftMouseUp, NSPoint(x: first.midX + 12, y: first.midY - 200)))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func aRingedSpaceKeepsItsRingWhileTheDotsMove() throws {
        #expect(try secondDotSnapshot(ringed: true) != secondDotSnapshot(ringed: false),
                "the dragged strip draws the ring of a space another window shows")
    }
}
