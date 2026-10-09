import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// Main-actor state that a test reads after a notification was posted off main.
@MainActor
private final class MainThreadLog {
    var calls = 0
    var offMain = 0
    func record() {
        calls += 1
        if !Thread.isMainThread { offMain += 1 }
    }
}

/// Posts `name` from a background thread and returns when the post returned.
private func postOffMain(_ name: Notification.Name, object: AnyObject?, on center: NotificationCenter) async {
    let post = OffMainPost(name: name, object: object, center: center)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            post.send()
            done.resume()
        }
    }
}

/// One post handed to a background thread (`Thread.detachNewThread`, never
/// main); the object is only passed through.
private nonisolated final class OffMainPost: @unchecked Sendable {
    let name: Notification.Name
    let object: AnyObject?
    let center: NotificationCenter
    init(name: Notification.Name, object: AnyObject?, center: NotificationCenter) {
        self.name = name
        self.object = object
        self.center = center
    }
    func send() {
        center.post(name: name, object: object)
    }
}

/// Waits on main (bounded) until `done` holds.
@MainActor
private func waitOnMain(_ done: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !done(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// AppKit and WebKit post window and workspace notifications off the main
/// thread too. A selector observer whose target is main-actor isolated trapped
/// the whole process there (signal 5, Swift's isolation check; KeyWindowObserver
/// trapped CmuxNextAppTests, #18771). Each observer must survive an off-main
/// post and do its work on main (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite(.serialized)
struct OffMainNotificationTests {
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The key window observer listens to every window (object: nil): a close
    /// posted off main clears that window's synthesized pointer on main.
    @Test func aWindowCloseOffMainClearsTheSynthesizedPointerOnMain() async throws {
        let window = Self.window()
        let content = try #require(window.contentView)
        let row = NSView(frame: NSRect(x: 20, y: 20, width: 200, height: 30))
        content.addSubview(row)
        let hover = PointerHover(row)
        PointerHover.setDebugPointer(NSPoint(x: 40, y: 30), in: window)
        #expect(PointerHover.debugPointers[ObjectIdentifier(window)] != nil)

        await postOffMain(NSWindow.willCloseNotification, object: window, on: .default)
        await waitOnMain { PointerHover.debugPointers[ObjectIdentifier(window)] == nil }
        #expect(PointerHover.debugPointers[ObjectIdentifier(window)] == nil)
        _ = hover
    }

    /// A key change posted off main refreshes that window's hover on main.
    @Test(.disabled("posts didBecomeKey off main on NotificationCenter.default, where ViewBridge's NSRemoteView observer touches a window off main and traps the whole run (SIGTRAP, run 37902730328); post on an injected center instead"))
    func aKeyChangeOffMainRefreshesHoverOnMain() async throws {
        let window = Self.window()
        defer { PointerHover.clearDebugPointer(in: window) }
        let content = try #require(window.contentView)
        let row = NSView(frame: NSRect(x: 20, y: 20, width: 200, height: 30))
        content.addSubview(row)
        let log = MainThreadLog()
        let hover = PointerHover(row) { _ in log.record() }
        // A stale hover: the pointer is over the row, and nothing refreshed yet.
        PointerHover.debugPointers[ObjectIdentifier(window)] = .init(point: NSPoint(x: 40, y: 30), mouse: NSEvent.mouseLocation)
        #expect(!hover.isHovering)

        await postOffMain(NSWindow.didBecomeKeyNotification, object: window, on: .default)
        await waitOnMain { hover.isHovering }
        #expect(hover.isHovering)
        #expect(log.calls == 1)
        #expect(log.offMain == 0)
    }

    /// A Reduce Transparency change posted off main repaints the window
    /// surface on main.
    ///
    /// `NSWorkspace.shared.notificationCenter` also feeds AppKit's own
    /// observers synchronously on the posting thread. On Xcode 26.6 that
    /// path can lay out an unrelated window and read `SidebarView.isFlipped`
    /// off-main, trapping before the queued cmux observer runs. Keep this
    /// process-global integration post disabled until the notification
    /// source is injectable, as with the key-window tests above.
    @Test(.disabled("NSWorkspace.shared.notificationCenter can make AppKit lay out a window off main and trap in SidebarView.isFlipped on Xcode 26.6; use an injected center for this coverage"))
    func aDisplayOptionsChangeOffMainRepaintsTheSurfaceOnMain() async {
        let window = Self.window()
        let log = MainThreadLog()
        let surface = WindowSurfaceView(content: NSView(), reduceTransparency: {
            log.record()
            return false
        })
        window.contentView = surface
        let before = log.calls

        await postOffMain(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
                          on: NSWorkspace.shared.notificationCenter)
        await waitOnMain { log.calls > before }
        #expect(log.calls > before)
        #expect(log.offMain == 0)
    }
}
