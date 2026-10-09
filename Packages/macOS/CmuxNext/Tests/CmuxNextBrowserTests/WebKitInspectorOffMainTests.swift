import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextBrowser

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
struct WebKitInspectorOffMainTests {
    /// The inspector watch listens to every window close (object: nil): a
    /// close posted off main does not trap, and the watch reads again on main.
    @Test func aWindowClosePostedOffMainDoesNotTrap() async {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let container = WebKitPageContainer(page: webView)
        let watch = WebKitInspectorWatch()
        watch.attach(webView: webView, container: container)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false

        await postOffMain(NSWindow.willCloseNotification, object: window)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            OperationQueue.main.addOperation { done.resume() }
        }
        #expect(!watch.isVisible)
    }
}
