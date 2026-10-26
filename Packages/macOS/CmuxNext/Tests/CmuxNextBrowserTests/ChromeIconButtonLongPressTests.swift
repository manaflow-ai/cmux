import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The browser toolbar's Back, Forward and Reload long press from the button's own mouse events and a deadline
/// (p06-scheduler-321, R-timer): no nested event wait holds the run loop. A release before the deadline is a
/// click; a press held past it shows the entry menu and does not click; a press held past it with no menu (a tab
/// that lists no entries) is still a click on its release, as the tracked press before it was.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ChromeIconButtonLongPressTests {
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
        let target: Target
        let button: ChromeIconButton
        let deadline = FakeDeadline()
        var menus: [NSMenu] = []

        /// `hasMenu`: the provider returns the tab's entries, or nil (no entries to list).
        init(hasMenu: Bool) {
            _ = NSApplication.shared
            window.isReleasedWhenClosed = false
            let target = Target()
            self.target = target
            button = ChromeIconButton(icon: .browserToolbarBack, label: "Back", action: #selector(Target.click(_:)), target: target,
                                      toolbar: true, toolTip: false)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
            content.addSubview(button)
            button.frame = NSRect(x: 20, y: 10, width: 28, height: 28)
            window.contentView = content
            button.longPressDeadline = deadline
            button.menuProvider = {
                guard hasMenu else { return nil }
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

    /// The press returns at once with the deadline armed for the hold delay; the release before it clicks once
    /// and drops the deadline.
    @Test func aQuickReleaseClicks() throws {
        let h = Harness(hasMenu: true)
        defer { h.window.close() }
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        #expect(h.button.isHoldingForMenu)
        #expect(h.button.isHighlighted, "the held press lost its pressed look")
        #expect(h.deadline.delay == ChromeIconButton.holdDelay)
        #expect(h.target.clicks == 0, "the press clicked before its release")
        h.button.mouseUp(with: try h.event(.leftMouseUp))
        #expect(h.target.clicks == 1)
        #expect(!h.deadline.isPending, "the release left the deadline armed")
        #expect(!h.button.isHighlighted)
        #expect(h.menus.isEmpty)
    }

    /// Held past the deadline with entries: the menu shows, and the release after it does not click.
    @Test func aHoldWithAMenuShowsItWithoutClicking() throws {
        let h = Harness(hasMenu: true)
        defer { h.window.close() }
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.deadline.fire()
        #expect(h.menus.count == 1)
        #expect(!h.button.isHoldingForMenu)
        h.button.mouseUp(with: try h.event(.leftMouseUp))
        #expect(h.target.clicks == 0, "the release after the menu also clicked")
    }

    /// Held past the deadline with no entries: no menu, and the release is still the click.
    @Test func aHoldWithNoMenuStillClicks() throws {
        let h = Harness(hasMenu: false)
        defer { h.window.close() }
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.deadline.fire()
        #expect(h.menus.isEmpty)
        #expect(h.button.isHoldingForMenu, "the hold ended with no menu to show")
        h.button.mouseUp(with: try h.event(.leftMouseUp))
        #expect(h.target.clicks == 1, "a slow click of a button with no menu did nothing")
    }

    /// The button leaves its window under a held press: the hold ends and its deadline is dropped.
    @Test func aHoldEndsWhenTheButtonLeavesItsWindow() throws {
        let h = Harness(hasMenu: true)
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
