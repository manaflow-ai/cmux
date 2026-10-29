import AppKit
@testable import CmuxNextDesign
import Testing

/// Back and Forward's long press from the button's own mouse events and a deadline: before,
/// `mouseDown` ran a `nextEvent(matching:)` loop that held the main thread until the release or the deadline.
/// A release before the double-click interval is a click; a press held past it shows the history menu.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TitlebarBandButtonTests {
    @MainActor private final class Target: NSObject {
        var clicks = 0
        @objc func click(_ sender: Any?) { clicks += 1 }
    }

    /// The deadline the test fires by hand.
    @MainActor private final class FakeDeadline: LongPressDeadline {
        private(set) var delay: Duration?
        private var action: (@MainActor () -> Void)?
        var isPending: Bool { action != nil }

        func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.action = action
        }

        func cancel() { action = nil }

        func fire() {
            let action = action
            self.action = nil
            action?()
        }
    }

    @MainActor private final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let button = TitlebarBandButton(symbol: "chevron.left")
        let target = Target()
        let deadline = FakeDeadline()
        var menus: [NSMenu] = []

        init() {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            button.frame = NSRect(x: 20, y: 10, width: 28, height: 28)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
            content.addSubview(button)
            window.contentView = content
            button.target = target
            button.action = #selector(Target.click(_:))
            button.longPressDeadline = deadline
            button.menuProvider = {
                let menu = NSMenu()
                menu.addItem(NSMenuItem(title: "Earlier page", action: nil, keyEquivalent: ""))
                return menu
            }
            button.presentMenu = { [unowned self] menu, _ in menus.append(menu) }
        }

        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
    }

    /// The press returns at once with the deadline armed for the double-click interval; the release before it
    /// runs the action once and drops the deadline.
    @Test func aReleaseBeforeTheDeadlineIsAClick() throws {
        let h = Harness()
        defer { h.window.close() }
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        #expect(h.button.isHoldingForMenu)
        #expect(h.deadline.isPending)
        #expect(h.deadline.delay == .seconds(NSEvent.doubleClickInterval))
        #expect(h.target.clicks == 0, "the press ran the action before its release")
        h.button.mouseDragged(with: try h.event(.leftMouseDragged))
        h.button.mouseUp(with: try h.event(.leftMouseUp))
        #expect(h.target.clicks == 1)
        #expect(!h.button.isHoldingForMenu)
        #expect(!h.deadline.isPending, "the release left the deadline armed")
        #expect(h.menus.isEmpty)
    }

    /// Held past the deadline: the menu shows, and the release after it runs nothing.
    @Test func aHoldPastTheDeadlineShowsTheMenu() throws {
        let h = Harness()
        defer { h.window.close() }
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.deadline.fire()
        #expect(h.menus.count == 1)
        #expect(!h.button.isHoldingForMenu)
        h.button.mouseUp(with: try h.event(.leftMouseUp))
        #expect(h.target.clicks == 0, "the release after the menu also ran the action")
    }

    /// The button leaves its window under a held press: the hold ends and its deadline is dropped.
    @Test func aHoldEndsWhenTheButtonLeavesItsWindow() throws {
        let h = Harness()
        defer { h.window.close() }
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.button.removeFromSuperview()
        #expect(!h.button.isHoldingForMenu)
        #expect(!h.deadline.isPending)
        h.deadline.fire()
        #expect(h.menus.isEmpty)
        #expect(h.target.clicks == 0)
    }
}
