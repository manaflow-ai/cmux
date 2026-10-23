import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// PROTOCOL.md "Terminal sizing policy": the Mac's policy can keep a shared
/// terminal at a grid wider than the phone's. The session tells the screen
/// the Mac's columns before any byte drawn for them, so the mirror is never
/// fed a wider grid's output at the phone's width (garbled text), and the
/// phone says it renders such a grid (`host-grid-view-v1`), so the daemon
/// stops capping the PTY at the phone's viewport.
@MainActor @Suite struct DaemonTerminalHostGridTests {
    @Test func theMacsColumnsAreKnownBeforeTheBytesDrawnForThem() {
        let session = DaemonTerminalSession(surface: 7) { throw LinkError(code: "unused", message: "") }
        #expect(session.remoteColumns == nil)
        var seen: [(event: TerminalSessionEvent, columns: Int?)] = []
        session.start { seen.append(($0, session.remoteColumns)) }
        session.handle(FakeTerminalDaemon.line(["event": "vt-state", "surface": 7, "cols": 120, "rows": 40,
                                                "data": Data("wide".utf8).base64EncodedString()]))
        #expect(seen.last?.event == .output(Data("wide".utf8)))
        #expect(seen.last?.columns == 120)
        session.handle(FakeTerminalDaemon.line(["event": "resized", "surface": 7, "cols": 50, "rows": 20,
                                                "replay": Data("narrow".utf8).base64EncodedString()]))
        let reset = seen.firstIndex { $0.event == .output(Data("\u{1B}c".utf8)) }
        #expect(reset.map { seen[$0].columns } == 50, "the reset already has the new columns")
        #expect(seen.last?.event == .output(Data("narrow".utf8)))
        #expect(session.remoteColumns == 50)
        #expect(session.remoteRows == 20)
    }

    @Test func thePhoneSaysItRendersTheMacsGrid() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let info = try #require(daemon.recorded.first { $0["cmd"] as? String == "set-client-info" })
        let capabilities = info["capabilities"] as? [String] ?? []
        #expect(capabilities.contains("host-grid-view-v1"))
        #expect(capabilities.contains("size-lease-v1"))
    }

    /// The suite's other tests' wait (DaemonTerminalSizeClaimTests): the
    /// fake daemon answers on its own task.
    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
