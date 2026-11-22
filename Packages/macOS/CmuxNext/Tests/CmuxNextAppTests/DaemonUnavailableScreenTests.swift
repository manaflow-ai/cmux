import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextDaemonRecovery
import Testing

/// The window cmux shows when its background service cannot start says so in plain words and
/// offers one action (POLISH.md: errors use plain words plus the action that fixes them, never
/// raw codes). The raw error stays one click away for a bug report.
@MainActor
struct DaemonUnavailableScreenTests {
    private func screen(_ error: DaemonError) -> DaemonConnectingView {
        _ = NSApplication.shared // performClick dispatches through NSApp
        let view = DaemonConnectingView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.apply(.unavailable(error))
        return view
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }

    @Test(arguments: [
        DaemonError.connectFailed(path: "/tmp/cmux-501/tui.sock", errno: ECONNREFUSED),
        DaemonError.binaryNotFound(searched: ["/Applications/cmux.app/Contents/Resources/bin/cmux-tui"]),
        DaemonError.launchFailed("exit status 1"),
        DaemonError.wrongApp("cmux-proxy"),
        DaemonError.unsupportedProtocol(9),
        DaemonError.sessionRestoreTimedOut("restore exceeded 120s"),
    ])
    func saysWhatHappenedInPlainWords(_ error: DaemonError) {
        let shown = screen(error).accessibilityLabel() ?? ""
        #expect(!shown.isEmpty)
        for raw in ["cmux-tui", "/tmp/", "/Applications/", "failed:", "exit status", "connect "] {
            #expect(!shown.contains(raw), "shows \(raw): \(shown)")
        }
    }

    /// While cmux starts (under the startup deadline, the shared bound) the window says nothing: no
    /// "Starting cmux…" (Leo, 2026-11-22: "entire classes of bullshit fucking error/status bullshit. fuck em.
    /// remove them all."). Past it the failure says one line with its buttons.
    @Test func startingSaysNothingUntilTheFailureWithItsButtons() {
        _ = NSApplication.shared
        let view = DaemonConnectingView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        #expect(view.titleText.isEmpty)
        #expect((view.accessibilityLabel() ?? "").isEmpty)
        #expect(buttons(in: view).allSatisfy(\.isHidden))
        view.apply(.unavailable(.connectFailed(path: "/tmp/cmux-501/tui.sock", errno: ECONNREFUSED)))
        #expect(view.titleText == DaemonRecoveryStrings.serviceUnavailable)
        #expect(view.accessibilityLabel() == DaemonRecoveryStrings.serviceUnavailable, "a retrying line came back")
        #expect(buttons(in: view).contains { !$0.isHidden })
        view.apply(.connected)
        #expect(view.titleText.isEmpty)
    }

    @Test func offersOneAction() {
        let actions = buttons(in: screen(.connectFailed(path: "/tmp/cmux-501/tui.sock", errno: ECONNREFUSED)))
            .filter { !$0.isHidden }
        #expect(actions.count == 1)
        #expect(actions.allSatisfy { !$0.title.isEmpty })
    }

    @Test func copyDetailsHandsOverTheRawError() throws {
        let error = DaemonError.connectFailed(path: "/tmp/cmux-501/tui.sock", errno: ECONNREFUSED)
        let view = screen(error)
        var copied: [String] = []
        view.copyToClipboard = { copied.append($0) }
        // The button's own target and action: a click outside a window may never dispatch.
        let button = try #require(buttons(in: view).first { !$0.isHidden })
        let action = try #require(button.action)
        _ = (try #require(button.target) as AnyObject).perform(action, with: button)
        #expect(copied == [String(describing: error)])
    }
}
