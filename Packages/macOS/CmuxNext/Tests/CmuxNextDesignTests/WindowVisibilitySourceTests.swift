import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// The one source of window visibility (p06-scheduler-022): the window node follows occlusion and
/// miniaturize through WindowEvents, under the app node that follows a hidden app and sleeping
/// displays through AppEvents; WindowDrawPolicy reads the window's source.
@MainActor @Suite(.timeLimit(.minutes(1))) struct WindowVisibilitySourceTests {
    private final class FakeWindowState {
        var value: Visibility = .visible
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .miniaturizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func miniaturizeThenDeminiaturizeFlipsTheNodeTwice() {
        let center = NotificationCenter()
        let window = Self.window()
        let state = FakeWindowState()
        let source = WindowVisibilitySource(window: window, name: "window", app: nil, events: WindowEvents(window: window, center: center)) { _ in
            state.value
        }
        var flips: [Visibility] = []
        let token = source.node.subscribe(owner: "test") { flips.append($0) }
        state.value = .hidden
        center.post(name: NSWindow.didMiniaturizeNotification, object: window)
        state.value = .visible
        center.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        #expect(flips == [.hidden, .visible])
        // A notice with no change flips nothing.
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(flips.count == 2)
        _ = token
    }

    @Test func occlusionMakesTheNodeOccludedAndTheWindowNotOnScreen() {
        let center = NotificationCenter()
        let window = Self.window()
        let state = FakeWindowState()
        let source = WindowVisibilitySource(window: window, name: "window", app: nil, events: WindowEvents(window: window, center: center)) { _ in
            state.value
        }
        #expect(source.isOnScreen)
        state.value = .occluded
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(source.node.effective == .occluded)
        #expect(!source.isOnScreen)
        // Another window's notice does not reach it.
        state.value = .visible
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: Self.window())
        #expect(source.node.effective == .occluded)
    }

    @Test func aHiddenAppHidesEveryWindowAndSleepingDisplaysOccludeThem() {
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let app = AppVisibilitySource(appEvents: AppEvents(center: appCenter), workspaceEvents: AppEvents(center: workspaceCenter),
                                      isAppHidden: false)
        let windows = (0..<3).map { _ in Self.window() }
        let sources = windows.map { window in
            WindowVisibilitySource(window: window, name: "window", app: app.node, events: WindowEvents(window: window, center: appCenter)) { _ in
                .visible
            }
        }
        #expect(sources.allSatisfy(\.node.isVisible))
        appCenter.post(name: NSApplication.didHideNotification, object: nil)
        #expect(sources.allSatisfy { $0.node.effective == .hidden })
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        appCenter.post(name: NSApplication.didUnhideNotification, object: nil)
        // Unhidden while the displays sleep: laid out, not seen.
        #expect(sources.allSatisfy { $0.node.effective == .occluded })
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(sources.allSatisfy(\.node.isVisible))
    }

    @Test func appStateHiddenWinsOverAsleep() {
        #expect(AppVisibilitySource.visibility(appHidden: true, screensAsleep: true) == .hidden)
        #expect(AppVisibilitySource.visibility(appHidden: false, screensAsleep: true) == .occluded)
        #expect(AppVisibilitySource.visibility(appHidden: false, screensAsleep: false) == .visible)
    }

    @Test func theDrawPolicyReadsTheWindowsSource() {
        let center = NotificationCenter()
        let window = Self.window()
        let state = FakeWindowState()
        let source = WindowVisibilitySource.of(window, events: WindowEvents(window: window, center: center)) { _ in state.value }
        #expect(WindowVisibilitySource.of(window) === source)
        #expect(WindowVisibilitySource.installed(on: window) === source)
        #expect(WindowDrawPolicy.isOnScreen(window))
        state.value = .occluded
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!WindowDrawPolicy.isOnScreen(window))
        state.value = .hidden
        center.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(!WindowDrawPolicy.isOnScreen(window))
    }

    @Test func aWindowWithNoSourceIsNotGivenOne() {
        let window = Self.window()
        _ = WindowDrawPolicy.isOnScreen(window)
        #expect(WindowVisibilitySource.installed(on: window) == nil)
    }
}
