import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A long run's working toast (Moving to Cloud) never times out, so nothing may leave it behind: a
/// one-window toast shown in another window (the person switched windows while a large folder
/// copied) ends the one showing in the first.
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastOneWindowTests {
    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                 backing: .buffered, defer: true)
    }

    @Test func aOneWindowToastInAnotherWindowEndsTheOneLeftBehind() {
        let center = CmuxToastCenter(host: SilentToastHost())
        let first = Self.window(), second = Self.window()
        defer { first.closeAfterTest(); second.closeAfterTest() }
        let working = center.show(CmuxToast(id: "cloud-move-t1", message: "Moving", duration: CmuxToast.untilClosed, oneWindow: true), in: first)
        let other = center.show(CmuxToast(id: "cloud-move-t2", message: "Moving", duration: CmuxToast.untilClosed, oneWindow: true), in: first)
        let result = center.show(CmuxToast(id: "cloud-move-t1", message: "Moved", oneWindow: true), in: second)
        #expect(working.isDismissed, "the working toast stayed in the window the person left")
        #expect(!other.isDismissed, "another run's toast ended")
        #expect(center.toasts(in: first).map(\.message) == ["Moving"])
        #expect(center.toasts(in: second).map(\.message) == ["Moved"])
        other.dismiss()
        result.dismiss()
    }

    /// The result is quiet (the person closed the same failure a moment ago): it still ends the working
    /// toast, in its own window too, instead of leaving it up for good.
    @Test func aQuietResultStillEndsTheWorkingToast() {
        let center = CmuxToastCenter(host: SilentToastHost())
        let window = Self.window()
        defer { window.closeAfterTest() }
        let failure = CmuxToast(id: "cloud-start-t4", message: "Couldn't copy the folder", duration: .seconds(12), oneWindow: true)
        center.show(failure, in: window)
        _ = center.close(id: "cloud-start-t4", in: window)
        #expect(center.isQuieted(failure))
        let working = center.show(CmuxToast(id: "cloud-start-t4", message: "Moving", duration: CmuxToast.untilClosed, oneWindow: true), in: window)
        let again = center.show(failure, in: window)
        #expect(again.isDismissed)
        #expect(working.isDismissed, "the working toast stayed up after a quiet result")
        #expect(center.toasts(in: window).isEmpty)
    }

    /// `close(id:)` ends the toast in every window (Run on This Mac after the person switched windows).
    @Test func closeByIDEndsItInEveryWindow() {
        let center = CmuxToastCenter(host: SilentToastHost())
        let first = Self.window(), second = Self.window()
        defer { first.closeAfterTest(); second.closeAfterTest() }
        let working = center.show(CmuxToast(id: "cloud-start-t5", message: "Moving", duration: CmuxToast.untilClosed, oneWindow: true), in: first)
        center.close(id: "cloud-start-t5")
        #expect(working.isDismissed)
        #expect(center.toasts(in: first).isEmpty && center.toasts(in: second).isEmpty)
    }

    /// Without the flag a toast stays per window, as before.
    @Test func anOrdinaryToastStaysPerWindow() {
        let center = CmuxToastCenter(host: SilentToastHost())
        let first = Self.window(), second = Self.window()
        defer { first.closeAfterTest(); second.closeAfterTest() }
        let a = center.show(CmuxToast(id: "notice", message: "One"), in: first)
        let b = center.show(CmuxToast(id: "notice", message: "Two"), in: second)
        #expect(!a.isDismissed)
        a.dismiss()
        b.dismiss()
    }
}

@MainActor
private final class SilentToastHost: CmuxToastHosting {
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {}
    func move(_ toast: CmuxToastView, to slot: Int) {}
    func hide(_ toast: CmuxToastView, animated: Bool) {}
}
