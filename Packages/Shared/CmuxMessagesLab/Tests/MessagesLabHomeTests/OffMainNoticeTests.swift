import AppKit
import Testing
@testable import MessagesLabHome

/// AppKit may post window notices off the main thread. A selector observer
/// runs on the posting thread, so its main-actor work ran off main (in Swift
/// 6 code it trapped, #18771). The compose field's key-window observers use
/// `queue: .main`: a notice posted off main runs its work on main
/// (plans/cmux-next/crash-elimination.md, P1b).
@MainActor @Suite(.serialized) struct OffMainNoticeTests {
    /// The field's superview; records the thread each subview arrives on.
    final class RecordingHost: NSView {
        var caretThreads: [Bool] = []
        override func didAddSubview(_ subview: NSView) {
            super.didAddSubview(subview)
            if subview is CaretView { caretThreads.append(Thread.isMainThread) }
        }
    }

    final class Box: @unchecked Sendable {
        let object: AnyObject
        init(_ object: AnyObject) { self.object = object }
    }

    /// Posts from a background thread; returns when the post returned.
    static func postOffMain(_ name: Notification.Name, object: AnyObject) async {
        let box = Box(object)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                NotificationCenter.default.post(name: name, object: box.object)
                done.resume()
            }
        }
    }

    @Test func aKeyChangePostedOffMainPlacesTheCaretOnMain() async throws {
        try #require(FieldTextView.ownCaret)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = RecordingHost(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = host
        let field = FieldTextView(frame: NSRect(x: 10, y: 10, width: 300, height: 30))
        host.addSubview(field)
        host.subviews.filter { $0 is CaretView }.forEach { $0.removeFromSuperview() }
        host.caretThreads = []

        await Self.postOffMain(NSWindow.didBecomeKeyNotification, object: window)
        let deadline = ContinuousClock.now + .seconds(5)
        while host.caretThreads.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(host.caretThreads == [true], "the caret work runs on main, once")
    }
}
