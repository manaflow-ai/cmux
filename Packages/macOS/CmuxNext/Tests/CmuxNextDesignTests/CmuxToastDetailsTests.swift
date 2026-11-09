import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Testing

/// A toast's Details shows the details in the toast itself, never somewhere else (Leo 2026-10-29:
/// "the FUCKING details are FUCKING STUPID BECAUSE IT TAKES YOU TO FUCKING SETTINGS????"). The
/// center owns whether they show (`showsDetails(serial:)`, `CmuxToastShown.showsDetails`); the host
/// only draws it.
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastDetailsTests {
    private static let reason = "Bootstrap failed: 125: Domain does not support specified action (launchctl bootstrap gui/501)"

    private static func toast(detail: String? = reason) -> CmuxToast {
        CmuxToast(id: "daemon-update.failures", message: "Couldn't update lab-mini", detail: detail,
                  action: .details("Details"), duration: CmuxToast.untilClosed)
    }

    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                 backing: .buffered, defer: true)
    }

    /// Details shows the detail in the same toast (same serial, same message and detail); again, it
    /// hides it and the toast is as it was.
    @Test func detailsShowTheDetailInTheToastAndHideItAgain() throws {
        let host = KeepingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        let handle = center.show(Self.toast(), in: window)
        let closed = try #require(host.shown.last)
        #expect(!closed.showsDetails)
        #expect(!center.showsDetails(serial: closed.serial))
        #expect(closed.toast.detail == Self.reason)
        #expect(closed.toast.action?.title == "Details")

        center.personRanAction(serial: closed.serial)
        let open = try #require(host.shown.last)
        #expect(host.shown.count == 1, "Details showed another toast")
        #expect(open.serial == closed.serial, "Details replaced the toast")
        #expect(open.showsDetails && center.showsDetails(serial: open.serial))
        #expect(open.toast == closed.toast)

        center.personRanAction(serial: open.serial)
        let again = try #require(host.shown.last)
        #expect(again == closed, "hiding the details left the toast changed")
        #expect(!center.showsDetails(serial: again.serial))
        handle.dismiss()
        #expect(host.shown.isEmpty)
    }

    /// A lit control keeps its fill with no pointer on it, and never takes the selection fill;
    /// it does not ask calm mode, which only stops the pointer's own hover fill.
    @Test func aLitControlKeepsTheHoverFill() {
        #expect(ChromeHover.fillColor(ChromeHover.State(lit: true)) != nil)
        #expect(ChromeHover.fillColor(ChromeHover.State(lit: true)) != Palette.selectionFill)
        #expect(ChromeHover.fillColor(ChromeHover.State()) == nil)
    }

    /// Details never ends the toast nor runs the handle's action (nothing opens elsewhere); the
    /// center's runAction (automation, as the button) toggles it the same way.
    @Test func detailsNeverEndTheToastOrRunItsAction() throws {
        let host = KeepingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        let handle = center.show(Self.toast(), in: window)
        var ran = 0
        handle.onAction = { ran += 1 }
        let serial = try #require(host.shown.last).serial

        #expect(center.runAction(id: "daemon-update.failures", in: window))
        #expect(center.showsDetails(serial: serial))
        #expect(host.shown.last?.showsDetails == true, "the host was not told the details show")
        center.personRanAction(serial: serial)
        #expect(!center.showsDetails(serial: serial))
        #expect(host.shown.last?.showsDetails == false)
        handle.runAction()
        #expect(ran == 0, "Details ran the toast's action")
        #expect(!handle.isDismissed, "Details ended the toast")
        #expect(center.toasts(in: window).count == 1)
        handle.dismiss()
    }

    /// Details on one toast leaves the others in its window as they are.
    @Test func detailsOnOneToastLeaveTheOthersClosed() throws {
        let host = KeepingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        let other = center.show(CmuxToast(id: "other", message: "Another failure", detail: "why", action: .details("Details")), in: window)
        let handle = center.show(Self.toast(), in: window)
        let serial = try #require(host.shown.last).serial
        center.personRanAction(serial: serial)
        #expect(host.shown.map(\.showsDetails) == [false, true])
        other.dismiss()
        handle.dismiss()
    }
}

/// The host's other reports: the pointer on a toast and a repeated toast.
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastHostReportTests {
    /// The pointer on a toast holds it past its time; leaving lets it end.
    @Test(.timeLimit(.minutes(1))) func hoverPausesTheDismissal() async throws {
        let host = KeepingToastHost()
        let clock = ManualClock()
        let center = CmuxToastCenter(clock: clock, host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let handle = center.show(CmuxToast(id: "t", message: "Closed “New Tab”", action: .undo(),
                                           duration: .milliseconds(150)), in: window)
        let dismissed = AsyncStream.makeStream(of: CmuxToastDismissReason.self)
        handle.onDismiss = { dismissed.continuation.yield($0) }
        let serial = try #require(host.shown.last).serial
        try await clock.waitForSleeper()
        center.pointer(onToast: serial, true)
        // On the toast, its time is off: nothing is asleep on the clock, so no amount of time ends it.
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(60))
        #expect(!handle.isDismissed)
        #expect(center.toasts(in: window).count == 1)
        center.pointer(onToast: serial, false)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(150))
        for await reason in dismissed.stream {
            #expect(reason == .timeout)
            break
        }
        #expect(handle.isDismissed)
        #expect(center.toasts(in: window).isEmpty)
        #expect(host.shown.isEmpty)
    }

    /// A repeated toast (the same refusal again) takes the shown one's place: the host is given one
    /// toast, the new one, in a single change.
    @Test func aSameIdToastReplacesTheShownOneInPlace() throws {
        let host = KeepingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let first = center.show(CmuxToast(id: "refusal", message: "Can’t close the last tab"), in: window)
        let shown = try #require(host.shown.last)
        let renders = host.renders

        let second = center.show(CmuxToast(id: "refusal", message: "Can’t close the last tab"), in: window)
        #expect(first.isDismissed)
        #expect(host.renders == renders + 1, "the replacement took more than one change")
        #expect(host.shown.count == 1)
        let replacement = try #require(host.shown.first)
        #expect(replacement.serial != shown.serial)
        #expect(replacement.toast == shown.toast)
        second.dismiss()
    }

    /// A fourth toast pushes the oldest out: the host is given the three newest, oldest first.
    @Test func aFourthToastPushesTheOldestOut() {
        let host = KeepingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let handles = (1...4).map { center.show(CmuxToast(id: "t\($0)", message: "Toast \($0)"), in: window) }
        #expect(handles[0].isDismissed)
        #expect(host.shown.map(\.toast.id) == ["t2", "t3", "t4"])
        handles.forEach { $0.dismiss() }
    }

    /// The window closed: its toasts end, and the host is not asked to draw in it again.
    @Test func aClosedWindowEndsItsToasts() {
        let host = KeepingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let handle = center.show(CmuxToast(id: "t", message: "Saved", duration: CmuxToast.untilClosed), in: window)
        let renders = host.renders
        center.windowClosed(window)
        #expect(handle.isDismissed)
        #expect(center.toasts(in: window).isEmpty)
        #expect(host.renders == renders, "the host was asked to draw in a closed window")
    }
}

/// Keeps the window's toasts as the center last showed them, and counts the changes.
@MainActor
private final class KeepingToastHost: CmuxToastHosting {
    private(set) var shown: [CmuxToastShown] = []
    private(set) var renders = 0
    func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter) {
        shown = toasts
        renders += 1
    }
}
