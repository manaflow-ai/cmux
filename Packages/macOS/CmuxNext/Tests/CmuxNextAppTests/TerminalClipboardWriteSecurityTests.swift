import AppKit
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

@MainActor
@Suite("Terminal clipboard write security")
struct TerminalClipboardWriteSecurityTests {
    private final class Delegate: TerminalSessionDelegate {
        var policyRequests = 0

        // This deliberately compiles before the protocol requires it. The
        // regression is that an unconfirmed Ghostty write never calls it.
        func terminalSessionAllowsClipboardWrite(_ session: TerminalSession) async -> Bool {
            policyRequests += 1
            return true
        }
    }

    @Test func silentGhosttyWritesConsultTheSessionTrustPolicy() async throws {
        _ = NSApplication.shared
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        let delegate = Delegate()
        session.delegate = delegate
        defer {
            session.close()
            io.finish()
        }

        let surface = try #require(session.surfaceView.surface)
        "text/plain".withCString { mime in
            "untrusted output".withCString { data in
                var item = ghostty_clipboard_content_s(mime: mime, data: data, len: "untrusted output".utf8.count)
                ghosttyWriteClipboard(ghostty_surface_userdata(surface), GHOSTTY_CLIPBOARD_STANDARD, &item, 1, false)
            }
        }

        for _ in 0..<20 where delegate.policyRequests == 0 {
            await Task.yield()
        }
        #expect(delegate.policyRequests == 1)
    }
}
