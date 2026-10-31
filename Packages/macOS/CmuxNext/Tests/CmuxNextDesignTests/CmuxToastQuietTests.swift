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
        host.shown.last?.onClose?()
        #expect(center.toasts(in: window).isEmpty)

        let again = center.show(notice, in: window)
        #expect(again.isDismissed)
        #expect(center.toasts(in: window).isEmpty)
        #expect(host.shown.count == 1, "the quiet notice made a second view")
        #expect(center.isQuieted(notice))
    }

    /// Only that message is quiet: another reason under the same id still shows.
    @Test func anotherMessageStillShows() {
        let host = RecordingToastHost()
        let center = CmuxToastCenter(host: host)
        let window = Self.window()
        defer { window.closeAfterTest() }
        center.show(CmuxToast(id: "refusal", message: "Not enough room to split this column"), in: window)
        host.shown.last?.onClose?()

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
        host.shown.last?.onClose?()
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
        host.shown.last?.onClose?()

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
        host.shown.last?.onClose?()
        #expect(center.isQuieted(notice))

        for _ in 0..<60 where center.isQuieted(notice) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!center.isQuieted(notice))
        let again = center.show(notice, in: window)
        #expect(!again.isDismissed)
        again.dismiss()
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
        host.shown.last?.onClose?()
        #expect(!center.isQuieted(notice))
        #expect(!center.show(notice, in: window).isDismissed)
    }
}

/// Records the views the center shows, so a test can press a toast's close button.
@MainActor
private final class RecordingToastHost: CmuxToastHosting {
    private(set) var shown: [CmuxToastView] = []
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {
        shown.append(toast)
    }
    func move(_ toast: CmuxToastView, to slot: Int) {}
    func hide(_ toast: CmuxToastView, animated: Bool) {}
}
