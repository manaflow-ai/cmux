import AppKit
@testable import CmuxNextDesign
import Testing

/// An overlay whose content grows or shrinks on its own (a SwiftUI popover) is hit-tested at its new size
/// with no frame notification (p03-rendering-038): the host checks its cached regions against the frames
/// they were built from, and its containers' layout re-routes the mouse under a pointer that did not move.
@MainActor
@Suite(.serialized)
struct OverlayContentResizeTests {
    @Test func aContentThatResizesItselfIsHitTestedAtItsNewSize() throws {
        let events = InputTapTestEvents()
        let window = InputTapTestEvents.window()
        let host = WindowOverlayHost.host(for: window)
        host.inputTap = events.tap
        defer {
            host.tearDown()
            window.orderOut(nil)
        }
        let away = NSPoint(x: -10_000, y: -10_000)
        host.pointerLocation = { away }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 40))
        let handle = host.present(content, options: OverlayOptions(kind: .attached, anchor: NSRect(x: 40, y: 40, width: 60, height: 40)))
        defer { handle.dismiss() }
        #expect(!content.postsFrameChangedNotifications, "the host turned the content's frame notifications on")
        let before = try #require(host.interactiveRegions().first)
        #expect(before.size == NSSize(width: 60, height: 40))

        content.setFrameSize(NSSize(width: 160, height: 120))
        let after = try #require(host.interactiveRegions().first)
        #expect(after.size == NSSize(width: 160, height: 120), "the host hit-tested the content at its old size")

        // A pointer resting where only the grown content reaches: the containers' layout takes the mouse there.
        let grownOnly = host.panel.convertPoint(toScreen: NSPoint(x: after.maxX - 4, y: after.maxY - 4))
        host.pointerLocation = { grownOnly }
        content.setFrameSize(NSSize(width: 60, height: 40))
        _ = host.interactiveRegions()
        #expect(host.panel.ignoresMouseEvents)
        content.setFrameSize(NSSize(width: 160, height: 120))
        host.panel.paneContainer.layout()
        host.panel.windowContainer.layout()
        #expect(!host.panel.ignoresMouseEvents, "the layout pass left the panel ignoring the mouse over the grown content")
    }
}
