import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// The browser toolbar's Back long press from the button's own mouse events and a deadline
/// (R-timer): no nested event wait holds the run loop. A release before the deadline is a
/// click; a press held past it shows the entry menu and does not click; a press held past it with no menu (a tab
/// that lists no entries, as a Chromium fork before API 14) is still a click on its release, as the tracked press
/// before it was.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ChromeIconButtonLongPressTests {
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

    /// A chrome in a window whose tab can go back, its Back button on a fake deadline and a recording presenter.
    @MainActor private final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let tab: MockBrowserTab
        let chrome: BrowserChromeView
        let deadline = FakeDeadline()
        var menus: [NSMenu] = []

        var button: ChromeIconButton { chrome.backButton }
        var backs: Int { tab.commands.filter { $0 == .goBack }.count }

        /// `listsEntries`: the tab lists its back entries (the menu), or lists none (no menu).
        init(listsEntries: Bool) throws {
            _ = NSApplication.shared
            let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/0")))
            tab.load(try #require(URL(string: "https://example.com/1")))
            if listsEntries {
                let entries = (0...1).map { BrowserNavigationEntry(url: URL(string: "https://example.com/\($0)"), title: "Page \($0)") }
                tab.navigation = BrowserNavigationList(entries: entries, current: 1)
            }
            self.tab = tab
            chrome = BrowserChromeView(tab: tab, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil)
            window.isReleasedWhenClosed = false
            chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            window.contentView = chrome
            chrome.layoutSubtreeIfNeeded()
            chrome.backButton.isEnabled = true
            chrome.backButton.longPressDeadline = deadline
            chrome.backButton.presentMenu = { [unowned self] menu, _ in menus.append(menu) }
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
        let h = try Harness(listsEntries: true)
        defer { h.window.close() }
        let before = h.backs
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        #expect(h.button.isHoldingForMenu)
        #expect(h.button.isHighlighted, "the held press lost its pressed look")
        #expect(h.deadline.delay == ChromeIconButton.holdDelay)
        #expect(h.backs == before, "the press clicked before its release")
        h.button.mouseUp(with: try h.event(.leftMouseUp))
        #expect(h.backs == before + 1)
        #expect(!h.deadline.isPending, "the release left the deadline armed")
        #expect(!h.button.isHighlighted)
        #expect(h.menus.isEmpty)
    }

    /// Held past the deadline with entries: the menu shows, and the release after it does not click.
    @Test func aHoldWithAMenuShowsItWithoutClicking() throws {
        let h = try Harness(listsEntries: true)
        defer { h.window.close() }
        let before = h.backs
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.deadline.fire()
        #expect(h.menus.map { $0.items.map(\.title) } == [["Page 0"]])
        #expect(!h.button.isHoldingForMenu)
        h.button.mouseUp(with: try h.event(.leftMouseUp))
        #expect(h.backs == before, "the release after the menu also clicked")
    }

    /// Held past the deadline with no entries: no menu, and the release is still the click.
    @Test func aHoldWithNoMenuStillClicks() throws {
        let h = try Harness(listsEntries: false)
        defer { h.window.close() }
        let before = h.backs
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.deadline.fire()
        #expect(h.menus.isEmpty)
        #expect(h.button.isHoldingForMenu, "the hold ended with no menu to show")
        h.button.mouseUp(with: try h.event(.leftMouseUp))
        #expect(h.backs == before + 1, "a slow click of Back with no entry menu did nothing")
    }

    /// The button leaves its window under a held press: the hold ends and its deadline is dropped.
    @Test func aHoldEndsWhenTheButtonLeavesItsWindow() throws {
        let h = try Harness(listsEntries: true)
        defer { h.window.close() }
        let before = h.backs
        h.button.mouseDown(with: try h.event(.leftMouseDown))
        h.button.removeFromSuperview()
        #expect(!h.button.isHoldingForMenu)
        #expect(!h.deadline.isPending)
        h.deadline.fire()
        #expect(h.menus.isEmpty)
        #expect(h.backs == before)
    }
}
