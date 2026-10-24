import AppKit
@testable import CmuxNextDesign
import Testing

/// Every Cmd-Tab or window switch (`NSWindow.didBecomeMain`), app activation, unhide and wake
/// resynced every status indicator the app had registered: the rows and spinners of every window,
/// covered or not. A window's indicators resync when that window becomes main; an app-wide moment
/// (activation, unhide, wake) resyncs only the windows on screen, once per turn, and a window that
/// was not on screen then catches up when it shows.
///
/// The count is `StatusIndicatorAppearance.resyncs`: the indicators that did the work (shown ones).
@MainActor @Suite(.serialized) struct StatusIndicatorWindowResyncTests {
    /// The app a test drives: its notice centers, the windows on screen, and the checks left for
    /// the next turn.
    @MainActor final class App {
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        var visible: Set<ObjectIdentifier> = []
        var pending: [@MainActor () -> Void] = []
        let appearance: StatusIndicatorAppearance
        var windows: [NSWindow] = []

        init() {
            appearance = StatusIndicatorAppearance(appCenter: center, workspaceCenter: workspace)
        }

        var environment: WindowKeyEnvironment {
            WindowKeyEnvironment(center: center, keyWindow: { nil }, isAppActive: { true },
                                 nextTurn: { [unowned self] check in self.pending.append(check) },
                                 workspaceCenter: workspace,
                                 isWindowVisible: { [unowned self] in self.visible.contains(ObjectIdentifier($0)) })
        }

        /// A window with `shown` indicators on screen and `parked` ones under a hidden ancestor (a
        /// parked workspace's rows).
        func window(shown: Int, parked: Int) -> Fixture {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            windows.append(window)
            // The window's tracker reads this app (made before any indicator moves in).
            _ = WindowKeyFamily.of(window, environment: environment)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = content
            let hidden = NSView(frame: content.bounds)
            hidden.isHidden = true
            content.addSubview(hidden)
            let fixture = Fixture(window: window, parked: hidden,
                                  shown: (0..<shown).map { _ in Self.indicator(in: content) },
                                  hidden: (0..<parked).map { _ in Self.indicator(in: hidden) })
            for view in fixture.shown + fixture.hidden { appearance.register(view) }
            return fixture
        }

        static func indicator(in parent: NSView) -> StatusIndicatorView {
            let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            parent.addSubview(view)
            view.configure(.working)
            return view
        }

        func show(_ windows: NSWindow...) {
            visible = Set(windows.map(ObjectIdentifier.init))
        }

        /// Posts `notices` in one turn and returns how many indicators did resync work; then runs
        /// the turn's deferred checks (the next turn).
        func post(_ notices: [(NotificationCenter, Notification.Name, AnyObject?)]) -> UInt64 {
            let before = StatusIndicatorAppearance.resyncs
            for (center, name, object) in notices { center.post(name: name, object: object) }
            let done = StatusIndicatorAppearance.resyncs - before
            let checks = pending
            pending.removeAll()
            for check in checks { check() }
            return done
        }

        func close() {
            for window in windows { window.close() }
        }
    }

    struct Fixture {
        let window: NSWindow
        let parked: NSView
        let shown: [StatusIndicatorView]
        let hidden: [StatusIndicatorView]
    }

    @Test func aWindowSwitchResyncsOnlyTheWindowThatBecameMain() {
        let app = App()
        defer { app.close() }
        let front = app.window(shown: 4, parked: 30), back = app.window(shown: 6, parked: 20)
        app.show(front.window, back.window)
        #expect(app.post([(app.center, NSWindow.didResignMainNotification, back.window),
                          (app.center, NSWindow.didBecomeMainNotification, front.window)]) == 4,
                "a window switch resynced indicators of a window whose state did not change")
        #expect(app.post([(app.center, NSWindow.didBecomeMainNotification, back.window)]) == 6)
    }

    @Test func aCmdTabResyncsTheWindowsOnScreenOnce() {
        let app = App()
        defer { app.close() }
        let front = app.window(shown: 4, parked: 30)
        _ = app.window(shown: 6, parked: 20) // covered, minimized or on another Space
        app.show(front.window)
        let cmdTab: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (app.center, NSApplication.didBecomeActiveNotification, nil),
            (app.center, NSWindow.didBecomeMainNotification, front.window),
            (app.center, NSWindow.didBecomeKeyNotification, front.window),
        ]
        #expect(app.post(cmdTab) == 4, "a Cmd-Tab resynced more than the front window's indicators, once")
        #expect(app.post(cmdTab) == 4)
    }

    @Test(arguments: [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                      NSWorkspace.sessionDidBecomeActiveNotification])
    func aWakeResyncsTheWindowsOnScreenAndAnotherCatchesUpWhenItShows(_ name: Notification.Name) {
        let app = App()
        defer { app.close() }
        let front = app.window(shown: 4, parked: 30), back = app.window(shown: 6, parked: 20)
        app.show(front.window)
        #expect(app.post([(app.workspace, name, nil)]) == 4, "a wake resynced a window that is not on screen")
        app.show(front.window, back.window)
        #expect(app.post([(app.center, NSWindow.didChangeOcclusionStateNotification, back.window)]) == 6,
                "a window that missed the wake did not catch up when it showed")
        #expect(app.post([(app.center, NSWindow.didChangeOcclusionStateNotification, back.window)]) == 0,
                "a window that owes nothing resynced on an occlusion change")
    }

    @Test(arguments: [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification])
    func anActivationWithNoWindowOnScreenResyncsNothing(_ name: Notification.Name) {
        let app = App()
        defer { app.close() }
        _ = app.window(shown: 4, parked: 30)
        _ = app.window(shown: 6, parked: 20)
        #expect(app.post([(app.center, name, nil)]) == 0)
    }

    @Test func aParkedIndicatorCatchesUpOnceWhenItShows() {
        let app = App()
        defer { app.close() }
        let front = app.window(shown: 2, parked: 50)
        app.show(front.window)
        #expect(app.post([(app.center, NSWindow.didBecomeMainNotification, front.window)]) == 2)
        let before = StatusIndicatorAppearance.resyncs
        front.parked.isHidden = false
        #expect(StatusIndicatorAppearance.resyncs - before == 50, "each parked indicator catches up once when it shows")
        front.parked.isHidden = true
        front.parked.isHidden = false
        #expect(StatusIndicatorAppearance.resyncs - before == 50, "an indicator that owed nothing resynced when it showed")
        #expect(app.post([(app.center, NSWindow.didBecomeMainNotification, front.window)]) == 52)
    }
}
