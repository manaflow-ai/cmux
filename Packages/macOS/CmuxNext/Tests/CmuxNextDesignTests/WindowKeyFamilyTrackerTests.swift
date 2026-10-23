import AppKit
@testable import CmuxNextDesign
import Testing

/// A4 (276b617df95): one key tracker per window decides the inactive wash. Before it, each
/// ``WindowMaterialView`` (the window backdrop and every pane with its own art) observed the key
/// and activation notices and checked the key window itself: O(material views in the session) work
/// per Cmd-Tab or focus move. Here a key change costs one check per window per turn (a Cmd-Tab posts
/// 3 to 6 notices in one turn), no view work when no window flips, view work only for the views of
/// the window that flipped, and nothing for a window that has no material view.
@MainActor
@Suite struct WindowKeyFamilyTrackerTests {
    /// The keyboard a test drives, and the checks the trackers left for the next turn.
    @MainActor
    final class Keyboard {
        let center = NotificationCenter()
        var key: NSWindow?
        var active = true
        var pending: [@MainActor () -> Void] = []

        var environment: WindowKeyEnvironment {
            WindowKeyEnvironment(center: center, keyWindow: { [unowned self] in self.key }, isAppActive: { [unowned self] in self.active },
                                 nextTurn: { [unowned self] check in self.pending.append(check) })
        }

        /// Posts `name` and returns how many checks it scheduled; runs them (the next turn).
        @discardableResult
        func post(_ name: Notification.Name) -> Int { post([name]) }

        /// Posts `names` in one turn and returns how many checks they scheduled; runs them (the next turn).
        @discardableResult
        func post(_ names: [Notification.Name]) -> Int {
            for name in names { center.post(name: name, object: nil) }
            let checks = pending
            pending.removeAll()
            for check in checks { check() }
            return checks.count
        }
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// `count` material views in `window` (the backdrop and pane backdrops).
    private static func addViews(_ count: Int, to window: NSWindow) -> [WindowMaterialView] {
        (0..<count).map { _ in
            let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
            window.contentView?.addSubview(view)
            return view
        }
    }

    @Test func aKeyChangeChecksOncePerWindowAndUpdatesOnlyTheFlippedWindowsViews() {
        let keyboard = Keyboard()
        let measured = Self.window(), other = Self.window()
        let measuredFamily = WindowKeyFamily.of(measured, environment: keyboard.environment)
        let otherFamily = WindowKeyFamily.of(other, environment: keyboard.environment)
        let views = Self.addViews(12, to: measured)
        _ = Self.addViews(3, to: other)
        keyboard.post([]) // the trackers' first checks, scheduled when their first view arrived
        // Every view of a window shares its one tracker.
        #expect(WindowKeyFamily.of(measured) === measuredFamily)
        #expect(measuredFamily.viewCount == 12 && otherFamily.viewCount == 3)

        keyboard.key = measured
        // One check per window for a notice, however many material views there are.
        #expect(keyboard.post(NSWindow.didBecomeKeyNotification) == 2)
        #expect(measuredFamily.viewUpdates == 0 && otherFamily.viewUpdates == 0)
        // The same key again: nothing flips, no view work.
        keyboard.post(NSWindow.didBecomeMainNotification)
        #expect(measuredFamily.viewUpdates == 0 && otherFamily.viewUpdates == 0)

        // The other window takes the keyboard (resign and become, key and main, in one turn): one
        // check per window for the whole turn; only the measured window flips, and only its views update.
        keyboard.key = other
        let before = (measuredFamily.checks, otherFamily.checks)
        #expect(keyboard.post([NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                               NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]) == 2)
        #expect(measuredFamily.checks == before.0 + 1 && otherFamily.checks == before.1 + 1)
        #expect(measuredFamily.isInactive && !otherFamily.isInactive)
        #expect(measuredFamily.viewUpdates == views.count)
        #expect(otherFamily.viewUpdates == 0)

        // Cmd-Tab away (resign key, resign main, resign active in one turn): the other window flips
        // now (its family held the keyboard); the measured one stays inactive.
        keyboard.key = nil
        keyboard.active = false
        #expect(keyboard.post([NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                               NSApplication.didResignActiveNotification]) == 2)
        #expect(measuredFamily.viewUpdates == views.count)
        #expect(otherFamily.viewUpdates == 3 && otherFamily.isInactive)
    }

    @Test func aViewLeavingItsWindowLeavesTheTracker() {
        let keyboard = Keyboard()
        let window = Self.window()
        let family = WindowKeyFamily.of(window, environment: keyboard.environment)
        let views = Self.addViews(2, to: window)
        views[0].removeFromSuperview()
        #expect(family.viewCount == 1)
    }

    @Test func aWindowWithNoMaterialViewChecksNothing() {
        let keyboard = Keyboard()
        let window = Self.window()
        let family = WindowKeyFamily.of(window, environment: keyboard.environment)
        // No view yet: a key change schedules no check.
        #expect(!family.isObserving)
        #expect(keyboard.post(NSWindow.didBecomeKeyNotification) == 0)

        let views = Self.addViews(2, to: window)
        #expect(family.isObserving)
        #expect(keyboard.post(NSWindow.didBecomeKeyNotification) == 1)

        // Its last view left (a swapped backdrop, a reused panel): the observers go with it.
        for view in views { view.removeFromSuperview() }
        #expect(!family.isObserving)
        let checks = family.checks
        #expect(keyboard.post([NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification]) == 0)
        #expect(family.checks == checks)

        // A view comes back: it observes again and reads where the keyboard is now.
        keyboard.key = window
        _ = Self.addViews(1, to: window)
        #expect(family.isObserving)
        #expect(keyboard.post([]) == 1)
        #expect(!family.isInactive)
    }
}
