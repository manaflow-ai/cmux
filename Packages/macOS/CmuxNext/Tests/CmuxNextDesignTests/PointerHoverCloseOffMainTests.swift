#if DEBUG
import AppKit
@testable import CmuxNextDesign
import Testing

/// `PointerHover`'s close observer watches every window's close notice
/// (`object: nil`), so it also hears notices posted off the main thread. It
/// trapped there in the main-actor check (CI, BrowserPopupPanelThreadTests:
/// SIGTRAP in `KeyWindowObserver.windowWillClose`); it now forgets the
/// window's pointer on main instead (crash-elimination.md, P1b).
@MainActor @Suite(.serialized)
struct PointerHoverCloseOffMainTests {
    @Test func aCloseNoticePostedOffMainForgetsThePointerOnMain() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        PointerHover.setDebugPointer(NSPoint(x: 10, y: 10), in: window)
        #expect(PointerHover.debugPointers[ObjectIdentifier(window)] != nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
                // The forget is queued on main before this resume.
                DispatchQueue.main.async { done.resume() }
            }
        }
        #expect(PointerHover.debugPointers[ObjectIdentifier(window)] == nil)
    }
}
#endif
