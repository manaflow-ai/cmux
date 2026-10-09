import AppKit
import Foundation
import Testing
@testable import CmuxNextPalette

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
struct PaletteOffMainNotificationTests {
    /// A clip bounds notice posted off main does not trap; the list
    /// re-hit-tests its hover on main (no pointer over the list here, so no
    /// hover is reported).
    @Test func aClipMovePostedOffMainDoesNotTrap() async {
        let list = PaletteListView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = list
        var hovers: [String?] = []
        var offMain = 0
        list.onHover = { id in
            hovers.append(id)
            if !Thread.isMainThread { offMain += 1 }
        }

        await postOffMain(NSView.boundsDidChangeNotification, object: list.contentView)
        // One main turn after the post: the block queued on main has run.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            OperationQueue.main.addOperation { done.resume() }
        }
        #expect(offMain == 0)
    }
}
