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
