import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextPages

/// Posts `name` from a background thread and returns when the post returned.
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
struct PageOffMainNotificationTests {
    /// A menu-action notice for the page's own context menu, posted off
    /// main, still records the person's activation on main.
    @Test func aContextMenuChoicePostedOffMainIsAUserActivationOnMain() async throws {
        let web = PageWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let menu = NSMenu()
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        web.willOpenMenu(menu, with: click)
        #expect(!web.hasRecentUserGesture())

        await postOffMain(NSMenu.willSendActionNotification, object: menu)
        await waitOnMain { web.hasRecentUserGesture() }
        #expect(web.hasRecentUserGesture())
    }
}
