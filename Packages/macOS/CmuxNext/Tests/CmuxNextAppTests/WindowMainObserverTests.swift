import AppKit
@testable import CmuxNextTabs
import Testing

/// The tab strip's main-window and occlusion follows (`WindowMainObserver`,
/// `WindowVisibilityObserver`) follow their window's `WindowNotices` (CmuxNextDesign): they report
/// the window's changes, a new window replaces the old one, a released follower reports nothing, and
/// the window is observed once for all of its strips. Each test posts on its own
/// `NotificationCenter`, so no test broadcasts to the app's (or another test's) observers.
@MainActor
@Suite
struct WindowMainObserverTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func reportsTheWindowBecomingAndLeavingMain() {
        _ = NSApplication.shared
        let window = Self.window()
        let center = NotificationCenter()
        let observer = WindowMainObserver(center: center)
        var seen: [Bool] = []
        observer.observe(window) { seen.append($0) }
        center.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(observer.isMain)
        center.post(name: NSWindow.didResignMainNotification, object: window)
        #expect(!observer.isMain)
        #expect(seen == [window.isMainWindow, true, false])
    }

    @Test func aNewWindowOrNilStopsFollowingTheOldOne() {
        _ = NSApplication.shared
        let first = Self.window(), second = Self.window()
        let center = NotificationCenter()
        let observer = WindowMainObserver(center: center)
        var seen: [Bool] = []
        observer.observe(first) { seen.append($0) }
        observer.observe(second) { seen.append($0) }
        center.post(name: NSWindow.didBecomeMainNotification, object: first)
        observer.observe(nil) { seen.append($0) }
        center.post(name: NSWindow.didBecomeMainNotification, object: second)
        #expect(seen == [first.isMainWindow, second.isMainWindow])
    }

    @Test func aReleasedObserverReportsNothing() {
        _ = NSApplication.shared
        let window = Self.window()
        let center = NotificationCenter()
        var observer: WindowMainObserver? = WindowMainObserver(center: center)
        var seen: [Bool] = []
        observer?.observe(window) { seen.append($0) }
        observer = nil
        center.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(seen == [window.isMainWindow])
        #expect(observer == nil)
    }

    /// Every pane's tab strip in a window follows that window's main changes: the window's
    /// notices are observed once for all of them, so a window with more strips registers no more
    /// observers (plans/cmux-next/PATTERNS.md P3, targeted observation).
    @Test func moreStripsInOneWindowRegisterNoMoreObservers() {
        _ = NSApplication.shared
        let window = Self.window()
        let center = CountingCenter()
        var seen: [Int: [Bool]] = [:]
        let first = WindowMainObserver(center: center)
        first.observe(window) { seen[0, default: []].append($0) }
        let oneStrip = center.registrations
        let others = (1...2).map { _ in WindowMainObserver(center: center) }
        for (index, observer) in others.enumerated() {
            observer.observe(window) { seen[index + 1, default: []].append($0) }
        }
        #expect(center.registrations == oneStrip)
        center.post(name: NSWindow.didBecomeMainNotification, object: window)
        for index in 0...2 { #expect(seen[index] == [window.isMainWindow, true]) }
    }

    /// A strip's occlusion follow (`WindowVisibilityObserver`) shares its window's observation with
    /// the main follow: adding it registers nothing, and an occlusion notice reaches it.
    @Test func theOcclusionFollowSharesTheWindowsObservation() {
        _ = NSApplication.shared
        let window = Self.window()
        let center = CountingCenter()
        let main = WindowMainObserver(center: center)
        main.observe(window) { _ in }
        let registered = center.registrations
        let visibility = WindowVisibilityObserver(center: center)
        var seen: [Bool] = []
        visibility.observe(window) { seen.append($0) }
        #expect(center.registrations == registered)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        let visible = window.occlusionState.contains(.visible)
        #expect(seen == [visible, visible])
    }
}

/// A center that counts observer registrations. The tests register and post on the main actor only.
private nonisolated final class CountingCenter: NotificationCenter, @unchecked Sendable {
    private(set) var registrations = 0

    override func addObserver(
        forName name: NSNotification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        registrations += 1
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
}
