import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// A busy tab's spinner checked itself again on every Cmd-Tab or window switch in every window of
/// the app (each busy cell was an app-wide indicator client). A window's busy tabs resync when that
/// window becomes main; a parked strip's tabs (a parked workspace in the same window) cost nothing
/// until the strip shows, then catch up once.
@MainActor @Suite(.serialized) struct TabStripIndicatorResyncTests {
    @MainActor final class App {
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        var visible: Set<ObjectIdentifier> = []
        var pending: [@MainActor () -> Void] = []
        var windows: [NSWindow] = []

        var environment: WindowKeyEnvironment {
            WindowKeyEnvironment(center: center, keyWindow: { nil }, isAppActive: { true },
                                 nextTurn: { [unowned self] check in self.pending.append(check) },
                                 workspaceCenter: workspace,
                                 isWindowVisible: { [unowned self] in self.visible.contains(ObjectIdentifier($0)) })
        }

        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            windows.append(window)
            _ = WindowKeyFamily.of(window, environment: environment)
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
            visible.insert(ObjectIdentifier(window))
            return window
        }

        /// A strip with `busy` working tabs and one idle tab in `window`.
        func strip(busy: Int, in window: NSWindow, hidden: Bool = false) -> TabStripView {
            var tabs = (0..<busy).map { index -> TabItem in
                var item = TabItem(id: TabID("busy\(index)"), title: "Agent \(index)")
                item.indicator = .working
                return item
            }
            tabs.append(TabItem(id: TabID("idle"), title: "Idle"))
            let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("idle")))
            strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
            strip.isHidden = hidden
            window.contentView?.addSubview(strip)
            return strip
        }

        func post(_ name: Notification.Name, object: AnyObject?) -> UInt64 {
            let before = StatusIndicatorAppearance.resyncs
            center.post(name: name, object: object)
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

    @Test func aWindowSwitchResyncsOnlyThatWindowsBusyTabs() {
        let app = App()
        defer { app.close() }
        let front = app.window(), back = app.window()
        _ = app.strip(busy: 3, in: front)
        _ = app.strip(busy: 5, in: back)
        #expect(app.post(NSWindow.didBecomeMainNotification, object: front) == 3,
                "a window switch resynced busy tabs of another window")
        #expect(app.post(NSWindow.didBecomeMainNotification, object: back) == 5)
    }

    @Test func aParkedStripsBusyTabsWaitUntilItShows() {
        let app = App()
        defer { app.close() }
        let front = app.window()
        _ = app.strip(busy: 2, in: front)
        let parked = app.strip(busy: 4, in: front, hidden: true)
        #expect(app.post(NSWindow.didBecomeMainNotification, object: front) == 2, "a parked strip's tabs did resync work")
        let before = StatusIndicatorAppearance.resyncs
        parked.isHidden = false
        #expect(StatusIndicatorAppearance.resyncs - before == 4, "the parked strip's busy tabs catch up once when it shows")
        parked.isHidden = true
        parked.isHidden = false
        #expect(StatusIndicatorAppearance.resyncs - before == 4)
    }
}
