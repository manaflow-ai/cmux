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

    /// Details shows the detail under the message, selectable, with the button a quiet Hide Details link; again, it
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
        // Open, it is a quiet link with an up chevron, never a filled chip (Leo, 2026-11-01).
        #expect(button.isOn && button.shownFill == nil, "the open Details button is a filled chip")
        #expect(button.image != nil && button.imagePosition == .imageTrailing, "the open Details button has no chevron")
        // On the title row's centre line with close.
        let buttonFrame = button.convert(button.bounds, to: view)
        let closeFrame = view.closeButton.convert(view.closeButton.bounds, to: view)
        #expect(abs(buttonFrame.midY - closeFrame.midY) < 0.5, "\(buttonFrame) \(closeFrame)")
        #expect(view.messageLabel?.maximumNumberOfLines == CmuxToastView.expandedMessageLines, "the message is still cut at three lines")
        #expect(view.fittingSize.height > closed.height + 8, "the toast did not grow to show the detail")
        #expect(view.fittingSize.width >= CmuxToastView.expandedMinWidth - 0.5, "the shown detail wraps in a narrow column")
        #expect(button.accessibilityLabel() == CmuxToastStrings.hideDetails, "the shown details have no Hide Details")

        button.performClick(nil)
        view.layoutSubtreeIfNeeded()
        #expect(!view.showsDetails && detail.isHidden && !button.isOn && button.image == nil)
        #expect(button.accessibilityLabel() == "Details")
        #expect(abs(view.fittingSize.width - closed.width) < 1, "hiding the details left the toast wide")
        #expect(button.shownFill == nil, "the Details button stayed lit after hiding the details")
        #expect(abs(view.fittingSize.height - closed.height) < 0.5)
        #expect(view.messageLabel?.themedToolTip == Self.reason)
    }

    /// Sized as the overlay host sizes it (its own frame, autoresizing), the shown detail sits
    /// under the message inside the toast, and the message stays at the top: the row's bottom pin
    /// is off while the details show, so the two layouts never fight.
    @Test func theShownDetailSitsUnderTheMessageInsideTheToast() throws {
        let view = CmuxToastView(toast: Self.toast())
        view.layoutSubtreeIfNeeded()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let closedHeight = view.frame.height
        view.setShowsDetails(true)
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let detail = try #require(view.detailLabel)
        let message = try #require(view.messageLabel)
        let detailFrame = detail.convert(detail.bounds, to: view)
        let messageFrame = message.convert(message.bounds, to: view)
        #expect(view.frame.height > closedHeight + 8)
        #expect(detailFrame.minY >= Metrics.space4 - 0.5 && detailFrame.maxY <= view.bounds.maxY + 0.5, "\(detailFrame) in \(view.bounds)")
        #expect(messageFrame.minY > detailFrame.maxY - 0.5, "the message is not above the detail: \(messageFrame) \(detailFrame)")
        #expect(view.bounds.maxY - messageFrame.maxY < closedHeight, "the message left the top of the toast")
    }

    /// A long detail (a daemon's or SSH's whole failure output) scrolls inside the toast at the
    /// cap: the toast never grows past it, and the row with Details and close stays inside it.
    @Test func aLongDetailScrollsAtTheCapAndKeepsTheButtonsInTheToast() throws {
        let long = (1...200).map { "line \($0): launchctl bootstrap gui/501 failed with 125" }.joined(separator: "\n")
        let view = CmuxToastView(toast: CmuxToast(id: "daemon-update.failures", message: String(repeating: "Couldn't update lab-mini. ", count: 30),
                                                  detail: long, action: .details("Details"), duration: CmuxToast.untilClosed))
        view.layoutSubtreeIfNeeded()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let closedHeight = view.frame.height
        view.setShowsDetails(true)
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let cap = CmuxToastView.detailCap(windowHeight: nil)
        let scroll = try #require(view.detailScroll)
        #expect(scroll.frame.height <= cap + 0.5, "the detail grew past its cap: \(scroll.frame.height)")
        #expect(scroll.documentView!.frame.height > scroll.frame.height, "the long detail does not scroll")
        // The message's six lines, the row's insets and the capped detail: nothing more.
        let message = try #require(view.messageLabel)
        #expect(view.fittingSize.height <= cap + closedHeight + message.frame.height + 2 * Metrics.space4 + 0.5,
                "the toast grew past the cap: \(view.fittingSize.height)")
        let button = try #require(view.actionButton)
        let close = view.closeButton
        for control in [button, close as NSView] {
            let frame = control.convert(control.bounds, to: view)
            #expect(view.bounds.contains(frame), "\(frame) outside \(view.bounds)")
        }
    }

    /// A window that shrinks after Details showed caps the detail again and the center sizes the
    /// toast, so the row with Details and close stays on screen. Shown as the app shows it (the
    /// center on the window's overlay host): the host's one observer of the window tells the toast,
    /// which keeps no window observer of its own.
    @Test func aShorterWindowCapsTheShownDetailAgain() throws {
        let long = (1...200).map { "line \($0): ssh build-box: install exited 1" }.joined(separator: "\n")
        let center = CmuxToastCenter(host: CmuxToastOverlayHost())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeWithOverlayHost() }
        let handle = center.show(CmuxToast(id: "daemon-update.failures", message: "Couldn't update lab-mini",
                                           detail: long, action: .details("Details"), duration: CmuxToast.untilClosed), in: window)
        let view = try #require(WindowOverlayHost.host(for: window).handles.lazy.compactMap { $0.content as? CmuxToastView }.first)
        #expect(center.runAction(id: "daemon-update.failures", in: window))
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.detailScroll)
        #expect(abs(scroll.frame.height - 240) < 0.5, "\(scroll.frame.height)")
        let tall = view.frame.height

        window.setContentSize(NSSize(width: 800, height: 300))
        view.layoutSubtreeIfNeeded()
        let cap = CmuxToastView.detailCap(windowHeight: view.window?.contentLayoutRect.height)
        #expect(cap < 240, "the toast's window did not follow the shorter window: \(cap)")
        #expect(scroll.frame.height <= cap + 0.5, "the detail kept its old cap: \(scroll.frame.height) > \(cap)")
        #expect(view.frame.height < tall - 1, "the center did not size the toast again: \(view.frame.height)")
        #expect(abs(view.frame.height - view.fittingSize.height) < 0.5, "\(view.frame.height) \(view.fittingSize.height)")
        handle.dismiss()
    }

    /// The cap is 240 pt, or 40% of a shorter window's height.
    @Test func theDetailCapFollowsTheWindow() {
        #expect(CmuxToastView.detailCap(windowHeight: nil) == 240)
        #expect(CmuxToastView.detailCap(windowHeight: 1000) == 240)
        #expect(CmuxToastView.detailCap(windowHeight: 400) == 160)
    }

    /// A lit control keeps its fill with no pointer on it, and never takes the selection fill;
    /// it does not ask calm mode, which only stops the pointer's own hover fill.
    @Test func aLitControlKeepsTheHoverFill() {
        #expect(ChromeHover.fillColor(ChromeHover.State(lit: true)) != nil)
        #expect(ChromeHover.fillColor(ChromeHover.State(lit: true)) != Palette.selectionFill)
        #expect(ChromeHover.fillColor(ChromeHover.State()) == nil)
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

    /// A toast stacked above one showing its details sits above that toast's real height; a slot
    /// with no toast in it counts as one as tall as this one (a toast pushed out moves one slot
    /// past the stack before its successor shows, and must stay clear of it).
    @Test func anEmptySlotBelowCountsAsTallAsTheToast() {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let even = CmuxToastOverlayHost.anchor(slot: 3, height: 36, in: bounds)
        #expect(CmuxToastOverlayHost.anchor(slot: 3, height: 36, in: bounds, below: [36, 36, 36]) == even)
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
        // As the overlay host does: the toast keeps its own frame.
        toast.translatesAutoresizingMaskIntoConstraints = true
        toast.frame = NSRect(origin: .zero, size: toast.fittingSize)
        views.append(toast)
    }
    func move(_ toast: CmuxToastView, to slot: Int) {}
    func hide(_ toast: CmuxToastView, animated: Bool) {}
}
