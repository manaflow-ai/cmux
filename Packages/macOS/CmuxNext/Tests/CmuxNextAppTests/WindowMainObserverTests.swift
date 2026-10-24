import AppKit
@testable import CmuxNextTabs
import Testing

/// The tab strip's main-window follow (`WindowMainObserver`) runs on `MainActorObservation` tokens:
/// it reports the window's main changes, a new window replaces the old one's observations, and a
/// released observer reports nothing.
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
        let observer = WindowMainObserver()
        var seen: [Bool] = []
        observer.observe(window) { seen.append($0) }
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(observer.isMain)
        NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: window)
        #expect(!observer.isMain)
        #expect(seen == [window.isMainWindow, true, false])
    }

    @Test func aNewWindowOrNilStopsFollowingTheOldOne() {
        _ = NSApplication.shared
        let first = Self.window(), second = Self.window()
        let observer = WindowMainObserver()
        var seen: [Bool] = []
        observer.observe(first) { seen.append($0) }
        observer.observe(second) { seen.append($0) }
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: first)
        observer.observe(nil) { seen.append($0) }
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: second)
        #expect(seen == [first.isMainWindow, second.isMainWindow])
    }

    @Test func aReleasedObserverReportsNothing() {
        _ = NSApplication.shared
        let window = Self.window()
        var observer: WindowMainObserver? = WindowMainObserver()
        var seen: [Bool] = []
        observer?.observe(window) { seen.append($0) }
        observer = nil
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(seen == [window.isMainWindow])
        #expect(observer == nil)
    }
}
