import AppKit
@testable import CmuxNextLayout
import CmuxNextWakeups
import Testing

/// p04-input-081 (MQ-main-nonswift): the layout root took its window's key changes through its
/// own `queue: .main` observers, one per root, outside any declared delivery. It now subscribes to
/// the window's one fan-out (``WindowEvents``) while it is live, and a key change still clears the
/// divider hover in the notice's own turn.
@MainActor
@Suite(.serialized) struct LayoutRootKeyWindowHoverTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Fixture {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        /// The window's posts in this test, on the fixture's own center.
        let center = NotificationCenter()
        let events: WindowEvents

        /// One column split top and bottom: its split divider is the one hover target.
        init() {
            let layout = ScreenLayout.columns([
                LayoutColumn(id: "c1", width: 1.0,
                             root: .split("x", axis: .vertical, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
            ])
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            root.context.reduceMotionOverride = true
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let events = WindowEvents(window: window, center: center)
            self.events = events
            root.context.hoverWindowEvents = { _ in events }
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
            for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}
        }

        var screen: ScreenContentView { root.screenViews["s"]! }
    }

    /// A live root holds one subscription per key notice on the window's events, which observe the
    /// window once; hidden, it holds none and the window's observer goes with it; shown, it
    /// subscribes again.
    @Test func aLiveRootSubscribesToTheWindowsKeyNoticesOnlyWhileLive() throws {
        let fixture = Fixture()
        let events = fixture.events
        try #require(fixture.root.isLive, "a root in a window is live")
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            #expect(events.subscriberCount(name) == 1, "the live root does not take \(name.rawValue) through the window's events")
            #expect(events.isObserving(name))
        }

        fixture.root.isHidden = true
        #expect(!fixture.root.isLive)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            #expect(events.subscriberCount(name) == 0, "a hidden root still hears \(name.rawValue)")
            #expect(!events.isObserving(name), "the window's observer outlived the root's subscription")
        }

        fixture.root.isHidden = false
        #expect(fixture.root.isLive)
        #expect(events.subscriberCount(NSWindow.didResignKeyNotification) == 1, "a shown root did not subscribe again")
    }

    /// The window resigning key clears a hovered divider in the notice's turn, with no mouse event.
    @Test func resigningKeyClearsTheDividerHoverInTheNoticesTurn() throws {
        let fixture = Fixture()
        let screen = fixture.screen
        let handle = try #require(screen.dividerViews[.split("x")])
        let rect = screen.convert(handle.cursorRectInBounds, from: handle)
        try #require(rect.width > 1 && rect.height > 1, "the divider shows: \(rect)")
        var isKey = true
        let point = CGPoint(x: rect.midX, y: rect.midY)
        fixture.root.context.hoverPointer = { _, _ in isKey ? screen.convert(point, to: nil) : nil }
        fixture.root.context.hoverReachesWindow = { _, _ in true }

        fixture.root.refreshDividerHover()
        try #require(handle.isHovered, "the pointer over the divider hovers it")

        isKey = false
        fixture.center.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        #expect(!handle.isHovered, "the window resigned key and its divider still shows hovered")
    }

    /// Both key notices run in the input class, in the notice's own turn (`// input-hop-allow:` at the
    /// subscription): resign clears the hover and become-key restores it before the post returns, with no
    /// run-loop turn between, one fan-out delivery per post.
    @Test func keyNoticesUpdateTheDividerHoverInTheInputsOwnTurn() throws {
        let fixture = Fixture()
        let screen = fixture.screen
        let handle = try #require(screen.dividerViews[.split("x")])
        let rect = screen.convert(handle.cursorRectInBounds, from: handle)
        try #require(rect.width > 1 && rect.height > 1, "the divider shows: \(rect)")
        var isKey = false
        let point = CGPoint(x: rect.midX, y: rect.midY)
        fixture.root.context.hoverPointer = { _, _ in isKey ? screen.convert(point, to: nil) : nil }
        fixture.root.context.hoverReachesWindow = { _, _ in true }
        fixture.root.refreshDividerHover()
        try #require(!handle.isHovered, "a window that is not key hovers no divider")

        isKey = true
        fixture.center.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        #expect(handle.isHovered, "the window became key and the divider under the pointer waits for a later turn")
        #expect(fixture.events.deliveries(NSWindow.didBecomeKeyNotification) == 1)

        isKey = false
        fixture.center.post(name: NSWindow.didResignKeyNotification, object: fixture.window)
        #expect(!handle.isHovered, "the window resigned key and the hover waits for a later turn")
        #expect(fixture.events.deliveries(NSWindow.didResignKeyNotification) == 1)
    }
}
