import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A toast's Details shows the details in the toast itself, never somewhere else (Leo 2026-10-29:
/// "the FUCKING details are FUCKING STUPID BECAUSE IT TAKES YOU TO FUCKING SETTINGS????").
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastDetailsTests {
    private static let reason = "Bootstrap failed: 125: Domain does not support specified action (launchctl bootstrap gui/501)"

    private static func toast(detail: String? = reason) -> CmuxToast {
        CmuxToast(id: "daemon-update.failures", message: "Couldn't update lab-mini", detail: detail,
                  action: .details("Details"), duration: CmuxToast.untilClosed)
    }

    /// Details shows the detail under the message, selectable, with the button lit; again, it
    /// hides it and the toast is as it was.
    @Test func detailsShowTheDetailInTheToastAndHideItAgain() throws {
        let view = CmuxToastView(toast: Self.toast())
        view.layoutSubtreeIfNeeded()
        let closed = view.fittingSize
        let detail = try #require(view.detailLabel)
        let button = try #require(view.actionButton)
        #expect(detail.isHidden)
        #expect(detail.stringValue == Self.reason)
        #expect(detail.isSelectable)
        #expect(view.messageLabel?.themedToolTip == Self.reason)

        button.performClick(nil)
        view.layoutSubtreeIfNeeded()
        #expect(view.showsDetails)
        #expect(!detail.isHidden)
        #expect(button.isOn, "the Details button is not lit while the details show")
        #expect(view.messageLabel?.maximumNumberOfLines == 0, "the message is still cut at three lines")
        #expect(view.fittingSize.height > closed.height + 8, "the toast did not grow to show the detail")
        #expect(abs(view.fittingSize.width - closed.width) < 1, "showing the detail changed the toast's width")

        button.performClick(nil)
        view.layoutSubtreeIfNeeded()
        #expect(!view.showsDetails && detail.isHidden && !button.isOn)
        #expect(abs(view.fittingSize.height - closed.height) < 0.5)
        #expect(view.messageLabel?.themedToolTip == Self.reason)
    }

    /// The hidden detail never widens the toast: a toast with Details is as wide as one without.
    @Test func aHiddenDetailKeepsTheToastsWidth() {
        let with = CmuxToastView(toast: Self.toast())
        let without = CmuxToastView(toast: CmuxToast(id: "t", message: "Couldn't update lab-mini", action: .details("Details")))
        with.layoutSubtreeIfNeeded()
        without.layoutSubtreeIfNeeded()
        #expect(abs(with.fittingSize.width - without.fittingSize.width) < 1)
        #expect(abs(with.fittingSize.height - without.fittingSize.height) < 0.5)
    }

    /// Details never ends the toast nor runs the handle's action (nothing opens elsewhere); the
    /// center's runAction (automation, as the button) toggles it the same way.
    @Test func detailsNeverEndTheToastOrRunItsAction() throws {
        let host = KeepingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeWithOverlayHost() }
        let handle = center.show(Self.toast(), in: window)
        var ran = 0
        handle.onAction = { ran += 1 }
        let view = try #require(host.views.last)
        let before = view.frame.height

        #expect(center.runAction(id: "daemon-update.failures", in: window))
        #expect(view.showsDetails)
        #expect(view.frame.height > before, "the center did not size the toast to its details")
        view.actionButton?.performClick(nil)
        #expect(!view.showsDetails)
        handle.runAction()
        #expect(ran == 0, "Details ran the toast's action")
        #expect(!handle.isDismissed, "Details ended the toast")
        #expect(center.toasts(in: window).count == 1)
    }

    /// A toast stacked above one showing its details sits above that toast's real height.
    @Test func aToastAboveATallerOneStacksOnItsHeight() {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let flat = CmuxToastOverlayHost.anchor(slot: 1, height: 36, in: bounds)
        let tall = CmuxToastOverlayHost.anchor(slot: 1, height: 36, in: bounds, below: [120])
        let base = CmuxToastOverlayHost.anchor(slot: 0, height: 120, in: bounds)
        #expect(tall.minY == base.minY + 120 + CmuxToastOverlayHost.stackGap)
        #expect(tall.minY > flat.minY)
        #expect(CmuxToastOverlayHost.anchor(slot: 1, height: 36, in: bounds, below: [36]) == flat, "equal heights moved")
    }
}

/// Keeps every view it is asked to show, so a test can click its buttons.
@MainActor
private final class KeepingToastHost: CmuxToastHosting {
    private(set) var views: [CmuxToastView] = []
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {
        toast.layoutSubtreeIfNeeded()
        toast.frame = NSRect(origin: .zero, size: toast.fittingSize)
        views.append(toast)
    }
    func move(_ toast: CmuxToastView, to slot: Int) {}
    func hide(_ toast: CmuxToastView, animated: Bool) {}
}
