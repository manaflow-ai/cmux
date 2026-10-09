import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextApp

/// Posts `name` from a background thread and returns when the post returned.
// global-notice-allow: deliberate off-main post on the real center to prove the app observer hops to main (crash-elimination P1b); AppKit's own observers of it can trap (#18815)
private func postOffMain(_ name: Notification.Name, object: AnyObject?, on center: NotificationCenter = .default) async {
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
    func send() { center.post(name: name, object: object) }
}

/// Waits on main (bounded) until `done` holds.
@MainActor
private func waitOnMain(_ done: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !done(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// AppKit and WebKit post notifications off the main thread too. A selector
/// observer whose target is main-actor isolated trapped the whole process
/// there (signal 5, Swift's isolation check; #18771). The observer must
/// survive an off-main post and do its work on main
/// (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite(.serialized)
struct AppOffMainNotificationTests {
    /// A scroller style change posted off main restyles the notifications
    /// list on main.
    @Test func aScrollerStyleChangeOffMainRestylesTheNotificationsListOnMain() async throws {
        let saved = SystemScrollers.preferredStyleOverride
        defer { SystemScrollers.preferredStyleOverride = saved }
        let panel = NotificationsPanelView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        let scroll = try #require(Self.scrollViews(in: panel).first)
        let target: NSScroller.Style = scroll.scrollerStyle == .legacy ? .overlay : .legacy
        SystemScrollers.preferredStyleOverride = target

        await postOffMain(NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        await waitOnMain { scroll.scrollerStyle == target }
        #expect(scroll.scrollerStyle == target)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { ($0 as? NSScrollView).map { [$0] } ?? scrollViews(in: $0) }
    }
}
