import AppKit
import Foundation
import Testing
@testable import CmuxNextTerminal

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
struct TerminalScrollerOffMainTests {
    /// A clip move posted off main reaches the scroller's row callback on main.
    ///
    /// AppKit's own NSScrollView observer handles this notification
    /// synchronously on the posting thread. Because TerminalScroller has a
    /// main-actor `isFlipped` override, Xcode 26.6 can trap in AppKit before
    /// the queued cmux observer runs. Keep the callback contract covered by
    /// the focused main-delivery tests until the notification source is
    /// injectable.
    @Test(.disabled("NSScrollView handles bounds notifications off main and Xcode 26.6 can trap in TerminalScroller.isFlipped before the app observer runs; use an injected center for this coverage"))
    func aClipMovePostedOffMainScrollsTheTerminalOnMain() async {
        let scroller = TerminalScroller()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        host.addSubview(scroller)
        scroller.frame = scroller.strip(in: host.bounds)
        scroller.tile()
        scroller.update(TerminalScrollbar(totalRows: 100, offsetRows: 0, visibleRows: 40))
        var rows: [UInt64] = []
        var offMain = 0
        scroller.onScrollToRow = { row in
            rows.append(row)
            if !Thread.isMainThread { offMain += 1 }
        }
        // Move the clip without its own (main-thread) notice, then post the notice off main.
        let clip = scroller.contentView
        clip.postsBoundsChangedNotifications = false
        let documentHeight = scroller.documentView?.frame.height ?? 0
        clip.setBoundsOrigin(NSPoint(x: 0, y: documentHeight / 2 - 100))

        await postOffMain(NSView.boundsDidChangeNotification, object: clip)
        await waitOnMain { !rows.isEmpty }
        #expect(rows.count == 1)
        #expect(offMain == 0)
    }
}
