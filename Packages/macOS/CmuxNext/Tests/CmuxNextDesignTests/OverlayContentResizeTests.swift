import AppKit
@testable import CmuxNextDesign
import Testing

/// An overlay whose content grows or shrinks on its own is hit-tested at its new size with no frame
/// notification. A content Auto Layout resizes (a SwiftUI popover) is read in its
/// holder's `layout()` during the panel's real layout pass; one that sets its own frame tells its handle.
/// Either way the panel takes the mouse under a pointer that did not move.
@MainActor
@Suite(.serialized)
struct OverlayContentResizeTests {
    private static let anchor = NSRect(x: 40, y: 40, width: 60, height: 40)

    /// `content` pinned at `origin` (its holder's coordinates) with width and height constraints it owns.
    private static func pin(_ content: NSView, at origin: NSPoint,
                            size: NSSize) throws -> (width: NSLayoutConstraint, height: NSLayoutConstraint) {
        let holder = try #require(content.superview)
        content.translatesAutoresizingMaskIntoConstraints = false
        let width = content.widthAnchor.constraint(equalToConstant: size.width)
        let height = content.heightAnchor.constraint(equalToConstant: size.height)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: origin.x),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -origin.y),
            width, height,
        ])
        return (width, height)
    }

    private static func host(_ window: NSWindow) -> (WindowOverlayHost, InputTapTestEvents) {
        let events = InputTapTestEvents()
        let host = WindowOverlayHost.host(for: window)
        host.inputTap = events.tap
        host.pointerLocation = { NSPoint(x: -10_000, y: -10_000) }
        return (host, events)
    }

    @Test(arguments: [false, true])
    func aContentAutoLayoutGrowsTakesTheMouseInTheLayoutPass(inPane: Bool) throws {
        let window = InputTapTestEvents.window()
        let (host, events) = Self.host(window)
        defer {
            host.tearDown()
            window.orderOut(nil)
            withExtendedLifetime(events) {}
        }
        let content = NSView(frame: NSRect(origin: .zero, size: Self.anchor.size))
        content.postsFrameChangedNotifications = false
        let layer: OverlayLayer? = inPane ? .pane(clip: NSRect(x: 0, y: 0, width: 300, height: 250)) : nil
        let handle = host.present(content, options: OverlayOptions(kind: .attached, anchor: Self.anchor, layer: layer))
        defer { handle.dismiss() }
        #expect(!content.postsFrameChangedNotifications, "the host turned the content's frame notifications on")
        // In a pane the holder is the overlay's clip, at the pane's origin (0, 0) here.
        let size = try Self.pin(content, at: Self.anchor.origin, size: Self.anchor.size)
        host.panel.layoutIfNeeded()
        let before = try #require(host.interactiveRegions().first)
        #expect(before == Self.anchor)

        // A pointer resting where only the grown content reaches.
        let grownOnly = host.panel.convertPoint(toScreen: NSPoint(x: Self.anchor.minX + 150, y: Self.anchor.minY + 110))
        host.pointerLocation = { grownOnly }
        host.updateMouseRouting()
        #expect(host.panel.ignoresMouseEvents)

        size.width.constant = 160
        size.height.constant = 120
        host.panel.layoutIfNeeded()
        #expect(content.frame.size == NSSize(width: 160, height: 120), "the layout pass did not size the content")
        #expect(!host.panel.ignoresMouseEvents, "the layout pass left the panel ignoring the mouse over the grown content")

        size.width.constant = 60
        size.height.constant = 40
        host.panel.layoutIfNeeded()
        #expect(host.panel.ignoresMouseEvents, "the layout pass kept the mouse where the content has gone")
    }

    @Test func aContentThatSetsItsOwnFrameTellsItsHandle() throws {
        let window = InputTapTestEvents.window()
        let (host, events) = Self.host(window)
        defer {
            host.tearDown()
            window.orderOut(nil)
            withExtendedLifetime(events) {}
        }
        let content = NSView(frame: NSRect(origin: .zero, size: Self.anchor.size))
        content.postsFrameChangedNotifications = false
        let handle = host.present(content, options: OverlayOptions(kind: .attached, anchor: Self.anchor))
        defer { handle.dismiss() }
        #expect(!content.postsFrameChangedNotifications, "the host turned the content's frame notifications on")

        let grownOnly = host.panel.convertPoint(toScreen: NSPoint(x: Self.anchor.minX + 150, y: Self.anchor.minY + 110))
        host.pointerLocation = { grownOnly }
        host.updateMouseRouting()
        #expect(host.panel.ignoresMouseEvents)

        content.setFrameSize(NSSize(width: 160, height: 120))
        handle.contentDidResize()
        #expect(try #require(host.interactiveRegions().first).size == NSSize(width: 160, height: 120))
        #expect(!host.panel.ignoresMouseEvents, "the handle left the panel ignoring the mouse over the grown content")

        content.setFrameSize(Self.anchor.size)
        handle.contentDidResize()
        #expect(host.panel.ignoresMouseEvents, "the handle kept the mouse where the content has gone")
    }
}
