import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups
import Testing

/// The one source of window visibility: the window node follows occlusion and
/// miniaturize through WindowEvents, under the app node that follows a hidden app and sleeping
/// displays through AppEvents; WindowDrawPolicy applies the same rule to AppKit's live state.
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

    /// The notice wiring (a fake read; the real AppKit mapping is
    /// ``realMiniaturizeThenDeminiaturizeFlipsTheNodeTwice()``).
    @Test func miniaturizeThenDeminiaturizeFlipsTheNodeTwice() {
        let center = NotificationCenter()
        let window = Self.window()
        let state = FakeWindowState()
        let events = WindowEvents(window: window, center: center)
        let source = WindowVisibilitySource(window: window, name: "window", app: nil, events: events) { _ in state.value }
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

    @Test func occlusionMakesTheNodeOccluded() {
        let center = NotificationCenter()
        let window = Self.window()
        let state = FakeWindowState()
        let events = WindowEvents(window: window, center: center)
        let source = WindowVisibilitySource(window: window, name: "window", app: nil, events: events) { _ in state.value }
        #expect(source.node.isVisible)
        state.value = .occluded
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(source.node.effective == .occluded)
        // Another window's notice does not reach it.
        state.value = .visible
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: Self.window())
        #expect(source.node.effective == .occluded)
    }

    /// AppKit reports a window under a same-size opaque cmux window as visible (crbug.com/883031);
    /// its occlusion family's verdict caps the node at occluded, and never lifts a miniaturized one.
    @Test func theOcclusionFamilyOccludesAWindowAppKitCallsVisible() {
        let center = NotificationCenter()
        let window = Self.window()
        let state = FakeWindowState()
        let events = WindowEvents(window: window, center: center)
        let source = WindowVisibilitySource(window: window, name: "window", app: nil, events: events) { _ in state.value }
        let family = WindowOcclusionFamily.of(window)
        #expect(source.node.isVisible)
        family.set(occluded: true)
        #expect(source.node.effective == .occluded)
        state.value = .hidden
        center.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(source.node.effective == .hidden)
        state.value = .visible
        center.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        #expect(source.node.effective == .occluded, "the family still says covered")
        family.set(occluded: false)
        #expect(source.node.isVisible)
    }

    @Test func aHiddenAppHidesEveryWindowAndSleepingDisplaysOccludeThem() {
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let appEvents = AppEvents(center: appCenter)
        let workspaceEvents = AppEvents(center: workspaceCenter)
        let app = AppVisibilitySource(appEvents: appEvents, workspaceEvents: workspaceEvents, isAppHidden: false)
        let windows = (0..<3).map { _ in Self.window() }
        let windowEvents = windows.map { WindowEvents(window: $0, center: appCenter) }
        let sources = zip(windows, windowEvents).map { window, events in
            WindowVisibilitySource(window: window, name: "window", app: app.node, events: events) { _ in .visible }
        }
        #expect(sources.allSatisfy { $0.node.isVisible })
        appCenter.post(name: NSApplication.didHideNotification, object: nil)
        #expect(sources.allSatisfy { $0.node.effective == .hidden })
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        appCenter.post(name: NSApplication.didUnhideNotification, object: nil)
        // Unhidden while the displays sleep: laid out, not seen.
        #expect(sources.allSatisfy { $0.node.effective == .occluded })
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        #expect(sources.allSatisfy { $0.node.isVisible })
    }

    @Test func appStateHiddenWinsOverAsleep() {
        #expect(AppVisibilitySource.visibility(appHidden: true, screensAsleep: true) == .hidden)
        #expect(AppVisibilitySource.visibility(appHidden: false, screensAsleep: true) == .occluded)
        #expect(AppVisibilitySource.visibility(appHidden: false, screensAsleep: false) == .visible)
    }

    /// Review of p06-scheduler-022: the sources keep their events. A subscription holds its fan-out
    /// weakly, so events nobody else kept (the app's workspace center) were released at once and
    /// display sleep never reached the app node.
    @Test func theSourcesKeepTheEventsTheyFollow() {
        let appCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let app = AppVisibilitySource(appEvents: AppEvents(center: appCenter), workspaceEvents: AppEvents(center: workspaceCenter),
                                      isAppHidden: false)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(app.node.effective == .occluded)
        appCenter.post(name: NSApplication.didHideNotification, object: nil)
        #expect(app.node.effective == .hidden)

        let center = NotificationCenter()
        let window = Self.window()
        let state = FakeWindowState()
        let source = WindowVisibilitySource(window: window, name: "window", app: nil, events: WindowEvents(window: window, center: center)) { _ in
            state.value
        }
        state.value = .hidden
        center.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(source.node.effective == .hidden)
    }

    /// Review of p06-scheduler-022: drawing reads AppKit live, not the node, so a reader whose own
    /// occlusion observer runs before the source's never gets a stale answer.
    @Test func theDrawPolicyReadsAppKitLiveNotTheNode() {
        let window = Self.window()
        let events = WindowEvents(window: window, center: NotificationCenter())
        // A node that says visible about a window that was never shown (AppKit: not on screen).
        let source = WindowVisibilitySource.of(window, events: events) { _ in .visible }
        #expect(WindowVisibilitySource.of(window) === source)
        #expect(WindowVisibilitySource.installed(on: window) === source)
        #expect(source.node.isVisible)
        #expect(WindowDrawPolicy.isOnScreen(window) == WindowVisibilitySource.appKitState(of: window).isVisible)
        #expect(!WindowDrawPolicy.isOnScreen(window))
    }

    /// The real AppKit mapping: a window never ordered in is not on screen.
    @Test func aWindowNeverShownIsOccluded() {
        let window = Self.window()
        #expect(WindowVisibilitySource.appKitState(of: window) == .occluded)
        let events = WindowEvents(window: window, center: NotificationCenter())
        let source = WindowVisibilitySource(window: window, name: "window", app: nil, events: events)
        #expect(source.node.effective == .occluded)
    }

    /// The real AppKit mapping and the real notices (the default read, the default center, a
    /// window server): miniaturize makes the node hidden, deminiaturize brings it back.
    @Test func realMiniaturizeThenDeminiaturizeFlipsTheNodeTwice() async {
        let window = Self.window()
        let events = WindowEvents(window: window)
        let source = WindowVisibilitySource(window: window, name: "window", app: nil, events: events)
        window.orderFrontRegardless()
        source.refresh()
        #expect(source.node.own != .hidden)
        let down = await Self.flips(of: source.node, until: { $0 == .hidden }) { window.miniaturize(nil) }
        #expect(down.last == .hidden)
        #expect(window.isMiniaturized)
        #expect(WindowVisibilitySource.appKitState(of: window) == .hidden)
        let back = await Self.flips(of: source.node, until: { $0 != .hidden }) { window.deminiaturize(nil) }
        #expect(back.count == 1)
        #expect(!window.isMiniaturized)
        #expect(source.node.own == WindowVisibilitySource.appKitState(of: window))
        window.close()
    }

    @Test func aWindowWithNoSourceIsNotGivenOne() {
        let window = Self.window()
        _ = WindowDrawPolicy.isOnScreen(window)
        #expect(WindowVisibilitySource.installed(on: window) == nil)
    }

    private final class FlipLog {
        var flips: [Visibility] = []
        var continuation: CheckedContinuation<Void, Never>?
    }

    /// The node's flips from `action` until one satisfies `done` (the suite's time limit bounds the wait).
    private static func flips(of node: VisibilityNode, until done: @escaping @MainActor (Visibility) -> Bool,
                              after action: () -> Void) async -> [Visibility] {
        let log = FlipLog()
        let token = node.subscribe(owner: "test") { visibility in
            log.flips.append(visibility)
            guard done(visibility) else { return }
            log.continuation?.resume()
            log.continuation = nil
        }
        await withCheckedContinuation { continuation in
            log.continuation = continuation
            action()
        }
        _ = token
        return log.flips
    }
}
