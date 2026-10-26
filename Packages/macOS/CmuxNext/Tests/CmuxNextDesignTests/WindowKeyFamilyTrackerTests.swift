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

    /// Leo 2026-10-25: "when i go out of focus of the cmux-next app i still see it turn more frosted
    /// like it frosts the glass before the background". AppKit redraws the glass for the key change
    /// at once; the wash then faded in over `scrim`, a second step. A settled key change now sets the
    /// wash with no animation, in the pass's own transaction, so the glass and the wash switch together.
    /// The wash eases only in a window on screen, so this needs a display (CI's GUI runners have one).
    @Test(.enabled("needs a display: the wash eases only in a window on screen") { !NSScreen.screens.isEmpty })
    func aSettledKeyChangeSwitchesTheWashWithNoFade() throws {
        let (keyboard, window, family, view) = try Self.onScreenGlass()
        defer { window.orderOut(nil) }
        let wash = try #require(view.inactiveTintView.layer)

        // Cmd-Tab away: the wash is at its resting alpha in this pass, with no fade on top.
        keyboard.key = nil
        keyboard.active = false
        keyboard.post([NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                       NSApplication.didResignActiveNotification])
        #expect(family.isInactive)
        #expect(view.inactiveTintAlpha > 0)
        #expect(!view.inactiveTintView.isHidden)
        #expect(wash.opacity == Float(view.inactiveTintAlpha))
        #expect(wash.animation(forKey: "opacity") == nil, "the wash fades in after the glass changed")

        // Back: the wash is gone in the same pass as well.
        keyboard.key = window
        keyboard.active = true
        keyboard.post([NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification])
        #expect(!family.isInactive)
        #expect(view.inactiveTintView.isHidden && wash.opacity == 0)
        #expect(wash.animation(forKey: "opacity") == nil, "the wash fades out after the glass changed")

        // Another window of this app takes the keys: settled too, no fade.
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        keyboard.key = other
        keyboard.post([NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification])
        #expect(family.isInactive)
        #expect(wash.animation(forKey: "opacity") == nil)
    }

    /// An active app with no key window may be between a resign and a become a later pass posts:
    /// the wash eases there, so a reversal one pass later does not flash (review of #25199).
    @Test(.enabled("needs a display: the wash eases only in a window on screen") { !NSScreen.screens.isEmpty })
    func anActiveAppWithNoKeyWindowStillEasesTheWash() throws {
        let (keyboard, window, family, view) = try Self.onScreenGlass()
        defer { window.orderOut(nil) }
        let wash = try #require(view.inactiveTintView.layer)
        keyboard.key = nil
        keyboard.post(NSWindow.didResignKeyNotification)
        #expect(family.isInactive)
        #expect(wash.animation(forKey: "opacity") != nil, "an unsettled key change should ease, not snap")

        // Another window takes the keys on a later pass: the state does not flip, but the easing
        // wash lands at once, with the settled change.
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        keyboard.key = other
        keyboard.post(NSWindow.didBecomeKeyNotification)
        #expect(family.isInactive)
        #expect(wash.animation(forKey: "opacity") == nil, "the settled change should land the wash")
        #expect(wash.opacity == Float(view.inactiveTintAlpha))
    }

    /// A glass backdrop in a titled window on screen whose family holds the keys.
    private static func onScreenGlass() throws -> (Keyboard, NSWindow, WindowKeyFamily, WindowMaterialView) {
        _ = NSApplication.shared
        let keyboard = Keyboard()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        try #require(window.isVisible)
        let family = WindowKeyFamily.of(window, environment: keyboard.environment)
        let view = WindowMaterialView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window.contentView?.addSubview(view)
        view.apply(WindowBackdrop(backgroundOpacity: 0.5, backgroundBlur: -1), tint: .black)
        keyboard.key = window
        keyboard.post([NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification])
        try #require(!family.isInactive && view.inactiveTintView.isHidden)
        return (keyboard, window, family, view)
    }
}
