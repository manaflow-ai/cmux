import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The page menu's Clear is the Mac's Clear Screen and Scrollback: the Mac's daemon clears
/// the terminal (`clear-history {surface}`, as `TerminalHandlers` sends it from a menu, with
/// no fallback key), not a Ctrl-L typed into the shell.
@MainActor @Suite struct DaemonTerminalClearHistoryTests {
    @Test func clearSendsClearHistoryForTheSurfaceAndNoKeys() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        #expect(session.clearsHistory)
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { daemon.recorded.contains { $0["cmd"] as? String == "resize-surface" } }

        try await session.clearHistory()
        let clear = try #require(daemon.recorded.first { $0["cmd"] as? String == "clear-history" })
        #expect(clear["surface"] as? Int == 7)
        #expect(clear["fallback_key"] == nil)
        // Nothing was typed into the shell for it.
        #expect(!daemon.recorded.contains { $0["cmd"] as? String == "send" })
    }

    @Test func clearBeforeTheAttachFailsWithoutSending() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        await #expect(throws: LinkError.self) { try await session.clearHistory() }
        #expect(!daemon.recorded.contains { $0["cmd"] as? String == "clear-history" })
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
