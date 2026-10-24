import AppKit
@testable import CmuxNextDesign
import Testing

/// A4 (276b617df95): one key tracker per window decides the inactive wash. Before it, each
/// ``WindowMaterialView`` (the window backdrop and every pane with its own art) observed the key
/// and activation notices and checked the key window itself: O(material views in the session) work
/// per Cmd-Tab or focus move. Then each window's tracker observed the notices itself: O(windows)
/// observers woken per notice. Here the app's ``WindowMoments`` hears each notice once and reads the
/// keyboard once per turn (a Cmd-Tab posts 3 to 6 notices in one turn); only the windows that held
/// or hold the keyboard check their look, no view work happens when no window flips, view work only
/// for the views of the window that flipped, and nothing for a window that has no material view.
@MainActor
@Suite struct WindowKeyFamilyTrackerTests {
    /// The keyboard a test drives, and the key reads the app's moments left for the next turn.
    @MainActor
    final class Keyboard {
        let center = CountingNotificationCenter()
        var key: NSWindow?
        var active = true
        var pending: [@MainActor () -> Void] = []

        /// The app's one listener for its windows' moments, reading this keyboard.
        lazy var moments = WindowMoments(app: center, workspace: NotificationCenter(),
                                         keyWindow: { [unowned self] in self.key }, mainWindow: { nil },
                                         isAppActive: { [unowned self] in self.active },
                                         nextTurn: { [unowned self] check in self.pending.append(check) })

        /// Posts `name` and returns how many key reads it scheduled; runs them (the next turn).
        @discardableResult
        func post(_ name: Notification.Name) -> Int { post([name]) }

        /// Posts `names` in one turn and returns how many key reads they scheduled; runs them (the next turn).
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

    @Test func aKeyChangeReadsTheKeyboardOnceAndChecksOnlyTheWindowsThatHeldOrHoldIt() {
        let keyboard = Keyboard()
        let measured = Self.window(), other = Self.window()
        let measuredFamily = WindowKeyFamily.of(measured, moments: keyboard.moments)
        let otherFamily = WindowKeyFamily.of(other, moments: keyboard.moments)
        // Windows the keyboard never visits (other workspaces' windows, covered windows).
        let bystanders = (0..<5).map { _ in Self.window() }
        let bystanderFamilies = bystanders.map { WindowKeyFamily.of($0, moments: keyboard.moments) }
        let views = Self.addViews(12, to: measured)
        _ = Self.addViews(3, to: other)
        for window in bystanders { _ = Self.addViews(2, to: window) }
        // One read for the whole turn: every tracker that started reads it once.
        #expect(keyboard.post([]) == 1)
        #expect(([measuredFamily, otherFamily] + bystanderFamilies).allSatisfy { $0.checks == 1 })
        // Every view of a window shares its one tracker.
        #expect(WindowKeyFamily.existing(measured) === measuredFamily)
        #expect(measuredFamily.viewCount == 12 && otherFamily.viewCount == 3)

        keyboard.key = measured
        // One read for a notice, however many windows and material views there are.
        #expect(keyboard.post(NSWindow.didBecomeKeyNotification) == 1)
        #expect(measuredFamily.viewUpdates == 0 && otherFamily.viewUpdates == 0)
        // The same key again: nothing flips, no view work.
        keyboard.post(NSWindow.didBecomeMainNotification)
        #expect(measuredFamily.viewUpdates == 0 && otherFamily.viewUpdates == 0)

        // The other window takes the keyboard (resign and become, key and main, in one turn): one
        // read for the whole turn, one check for each of the two windows; only the measured window
        // flips, and only its views update.
        keyboard.key = other
        let before = (measuredFamily.checks, otherFamily.checks)
        #expect(keyboard.post([NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                               NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]) == 1)
        #expect(measuredFamily.checks == before.0 + 1 && otherFamily.checks == before.1 + 1)
        #expect(measuredFamily.isInactive && !otherFamily.isInactive)
        #expect(measuredFamily.viewUpdates == views.count)
        #expect(otherFamily.viewUpdates == 0)

        // Cmd-Tab away (resign key, resign main, resign active in one turn): the other window flips
        // now (its family held the keyboard); the measured one cannot change and does not check.
        keyboard.key = nil
        keyboard.active = false
        let measuredChecks = measuredFamily.checks
        #expect(keyboard.post([NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                               NSApplication.didResignActiveNotification]) == 1)
        #expect(measuredFamily.checks == measuredChecks && measuredFamily.viewUpdates == views.count)
        #expect(otherFamily.viewUpdates == 3 && otherFamily.isInactive)

        // Cmd-Tab back to the other window: the measured window still holds no key and stays inactive.
        keyboard.key = other
        keyboard.active = true
        keyboard.post([NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification])
        #expect(!otherFamily.isInactive && otherFamily.viewUpdates == 6)
        #expect(measuredFamily.isInactive && measuredFamily.checks == measuredChecks)
        // No key move reached a window the keyboard never visited.
        #expect(bystanderFamilies.allSatisfy { $0.checks == 1 && $0.viewUpdates == 0 },
                "a key change checked a window that neither held nor holds the keyboard")
    }

    @Test func theInactiveDimSettingRedrawsEveryWindowWithAMaterialView() {
        let keyboard = Keyboard()
        let windows = (0..<2).map { _ in Self.window() }
        let families = windows.map { WindowKeyFamily.of($0, moments: keyboard.moments) }
        for window in windows { _ = Self.addViews(2, to: window) }
        keyboard.post([])
        keyboard.center.post(name: WindowMaterialView.inactiveDimDidChange, object: nil)
        #expect(families.allSatisfy { $0.viewUpdates == 2 })
    }

    /// The key, main and activation notices (and the inactive-dim setting) are heard once per app by
    /// one adapter, however many windows have a material view: each window's tracker used to
    /// register its own seven app-wide observers, so a Cmd-Tab woke one observer per window per
    /// notice (P3).
    @Test func theAppHearsEachKeyMomentOnceWhateverItsWindows() {
        let keyboard = Keyboard()
        let windows = (0..<3).map { _ in Self.window() }
        for window in windows { _ = WindowKeyFamily.of(window, moments: keyboard.moments) }
        let views = windows.map { Self.addViews(2, to: $0) }
        keyboard.post([])
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     WindowMaterialView.inactiveDimDidChange]
        for name in names {
            #expect(keyboard.center.observers(of: name) == 1, "\(name.rawValue) is observed more than once per app")
        }
        // The last material view of the app left: nothing listens.
        for view in views.joined() { view.removeFromSuperview() }
        for name in names {
            #expect(keyboard.center.observers(of: name) == 0, "\(name.rawValue) is still observed with no material view left")
        }
    }

    @Test func aViewLeavingItsWindowLeavesTheTracker() {
        let keyboard = Keyboard()
        let window = Self.window()
        let family = WindowKeyFamily.of(window, moments: keyboard.moments)
        let views = Self.addViews(2, to: window)
        views[0].removeFromSuperview()
        #expect(family.viewCount == 1)
    }

    @Test func aWindowWithNoMaterialViewChecksNothing() {
        let keyboard = Keyboard()
        let window = Self.window()
        let family = WindowKeyFamily.of(window, moments: keyboard.moments)
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
