import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Toasts come back less often (Lawrence 2026-10-18: "we show the toast in cmux-next too
/// often"): a notice the person closed stays quiet for a while, and the same toast again while
/// it shows is not announced again.
@MainActor
@Suite(.closesItsWindows)
struct CmuxToastQuietTests {
    private static func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                 backing: .buffered, defer: true)
    }

    /// The close button on a notice quiets it: the same message asked for again does not show.
    @Test func aClosedNoticeDoesNotComeBackAtOnce() {
        let host = RecordingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        let notice = CmuxToast(id: "refusal", message: "The agent chat column holds only agent chats.")
        center.show(notice, in: window)
        host.closeNewest()
        #expect(center.toasts(in: window).isEmpty)

        let again = center.show(notice, in: window)
        #expect(again.isDismissed)
        #expect(center.toasts(in: window).isEmpty)
        #expect(host.serialsShown.count == 1, "the quiet notice showed a second toast")
        #expect(center.isQuieted(notice))
    }

    /// Only that message is quiet: another reason under the same id still shows.
    @Test func anotherMessageStillShows() {
        let host = RecordingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        center.show(CmuxToast(id: "refusal", message: "Not enough room to split this column"), in: window)
        host.closeNewest()

        let other = center.show(CmuxToast(id: "refusal", message: "Can’t close the last tab"), in: window)
        #expect(!other.isDismissed)
        #expect(center.toasts(in: window).map(\.message) == ["Can’t close the last tab"])
        other.dismiss()
    }

    /// Only what it said is quiet: the same message with another detail (another subagent that
    /// could not be stopped, and why) still shows (Codex review of #23393).
    @Test func anotherDetailStillShows() {
        let host = RecordingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        let first = CmuxToast(id: "home.stopAllAgents", message: "1 could not be stopped", detail: "a2: refused")
        center.show(first, in: window)
        host.closeNewest()
        #expect(center.isQuieted(first))

        let other = center.show(CmuxToast(id: "home.stopAllAgents", message: "1 could not be stopped", detail: "a4: refused"), in: window)
        #expect(!other.isDismissed)
        other.dismiss()
    }

    /// A toast with an action (an Undo, a Retry) is never quieted: it may hold the person's work.
    @Test func aToastWithAnActionIsNeverQuieted() {
        let host = RecordingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        let undo = CmuxToast(id: "tab-closed", message: "Closed “zsh”", action: .undo())
        center.show(undo, in: window)
        host.closeNewest()

        let again = center.show(undo, in: window)
        #expect(!again.isDismissed)
        #expect(center.toasts(in: window).count == 1)
        again.dismiss()
    }

    /// A toast that ends by itself (its time ran out) or by code does not quiet anything.
    @Test func onlyThePersonsCloseQuiets() {
        let center = CmuxToastCenter(host: RecordingToastHost())
        let window = Self.window()
        defer { window.closeAfterTest() }
        let notice = CmuxToast(id: "saved", message: "Saved")
        center.show(notice, in: window).dismiss()

        let again = center.show(notice, in: window)
        #expect(!again.isDismissed)
        #expect(!center.isQuieted(notice))
        again.dismiss()
    }

    /// The quiet ends after the cooldown, and the notice shows again.
    @Test func theQuietEndsAfterTheCooldown() async throws {
        let host = RecordingToastHost()
        let center = CmuxToastCenter(host: host)
        center.closedCooldown = .milliseconds(100)
        let window = Self.window()
        defer { window.closeAfterTest() }
        let notice = CmuxToast(id: "refusal", message: "No pane to the left")
        center.show(notice, in: window)
        host.closeNewest()
        #expect(center.isQuieted(notice))

        for _ in 0..<60 where center.isQuieted(notice) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!center.isQuieted(notice))
        let again = center.show(notice, in: window)
        #expect(!again.isDismissed)
        again.dismiss()
    }

    /// A run's working toast the person closed stays closed for the rest of the run, whatever its next
    /// progress line says (Move to Cloud's step and countdown, Codex review of #39502); the run's result
    /// still shows, and the next run's working toast shows again.
    @Test func aClosedWorkingToastStaysClosedUntilItsResult() {
        let host = RecordingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        func working(_ message: String) -> CmuxToast {
            CmuxToast(id: "cloud-move-t1", message: message, duration: CmuxToast.untilClosed, oneWindow: true, working: true)
        }
        center.show(working("Moving to Cloud…\n1 of 4 · Connecting to dev · about 35 s left"), in: window)
        host.closeNewest()
        let shown = host.serialsShown.count
        for line in ["1 of 4 · Connecting to dev · about 30 s left", "2 of 4 · Copying the folder · about 25 s left"] {
            #expect(center.show(working("Moving to Cloud…\n" + line), in: window).isDismissed)
        }
        #expect(center.show(working("Updating dev…"), in: window).isDismissed, "a machine update's toast is the same run's")
        #expect(center.toasts(in: window).isEmpty && host.serialsShown.count == shown, "a closed working toast came back")
        #expect(center.show(CmuxToast(id: "cloud-move-t2", message: "Moving to Cloud…", duration: CmuxToast.untilClosed, working: true),
                            in: window).isDismissed == false, "another run's working toast stays")
        center.close(id: "cloud-move-t2")

        let result = center.show(CmuxToast(id: "cloud-move-t1", message: "Moved to dev", oneWindow: true), in: window)
        #expect(!result.isDismissed, "the result shows after its working toast was closed")
        result.dismiss()
        let next = center.show(working("Moving to Cloud…"), in: window)
        #expect(!next.isDismissed, "the next run's working toast shows, even with the same headline")
        next.dismiss()
    }

    /// A failure with Retry is a result too; a run ended by code (`close(id:)`) ends the quiet as well,
    /// and a working toast ended by code or its window closing quiets nothing.
    @Test func aWorkingToastsQuietEndsWithItsRun() {
        let host = RecordingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        let working = CmuxToast(id: "cloud-bring-back-t1", message: "Bringing back…", duration: CmuxToast.untilClosed, working: true)
        center.show(working, in: window)
        host.closeNewest()
        let failure = center.show(CmuxToast(id: "cloud-bring-back-t1", message: "Couldn't copy the folder", action: CmuxToast.Action(title: "Retry"),
                                            duration: .seconds(60)), in: window)
        #expect(!failure.isDismissed)
        failure.dismiss()
        #expect(!center.isQuieted(working))

        center.show(working, in: window)
        host.closeNewest()
        #expect(center.isQuieted(working))
        center.close(id: "cloud-bring-back-t1")
        #expect(!center.isQuieted(working))

        center.show(working, in: window).dismiss()
        #expect(!center.isQuieted(working), "only the person's close quiets")
    }

    /// A zero cooldown turns the quiet off.
    @Test func aZeroCooldownNeverQuiets() {
        let host = RecordingToastHost()
        let center = CmuxToastCenter(host: host)
        center.closedCooldown = .zero
        let window = Self.window()
        defer { window.closeAfterTest() }
        let notice = CmuxToast(id: "refusal", message: "No pane to the left")
        center.show(notice, in: window)
        host.closeNewest()
        #expect(!center.isQuieted(notice))
        #expect(!center.show(notice, in: window).isDismissed)
    }
}

/// Records what the center shows, so a test can press a toast's close button as the web host
/// reports it (`personClosed(serial:)`).
@MainActor
private final class RecordingToastHost: CmuxToastHosting {
    private(set) var renders: [[CmuxToastShown]] = []
    private weak var center: CmuxToastCenter?
    func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter) {
        renders.append(toasts)
        self.center = center
    }
    /// Every toast the host was given to draw, by serial.
    var serialsShown: Set<Int> { Set(renders.flatMap { $0.map(\.serial) }) }
    /// The person clicks the close button on the newest toast shown now.
    func closeNewest() {
        guard let serial = renders.last?.last?.serial else { return }
        center?.personClosed(serial: serial)
    }
}
