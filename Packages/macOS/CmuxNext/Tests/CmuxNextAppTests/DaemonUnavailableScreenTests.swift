import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The window cmux shows when its background service cannot start says so in plain words and
/// offers one action (POLISH.md: errors use plain words plus the action that fixes them, never
/// raw codes). The raw error stays one click away for a bug report.
@MainActor
struct DaemonUnavailableScreenTests {
    private func screen(_ error: DaemonError) -> DaemonConnectingView {
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
    ])
    func saysWhatHappenedInPlainWords(_ error: DaemonError) {
        let shown = screen(error).accessibilityLabel() ?? ""
        #expect(!shown.isEmpty)
        for raw in ["cmux-tui", "/tmp/", "/Applications/", "failed:", "exit status", "connect "] {
            #expect(!shown.contains(raw), "shows \(raw): \(shown)")
        }
    }

    @Test func offersOneAction() {
        let actions = buttons(in: screen(.connectFailed(path: "/tmp/cmux-501/tui.sock", errno: ECONNREFUSED)))
            .filter { !$0.isHidden }
        #expect(actions.count == 1)
        #expect(actions.allSatisfy { !$0.title.isEmpty })
    }
}
