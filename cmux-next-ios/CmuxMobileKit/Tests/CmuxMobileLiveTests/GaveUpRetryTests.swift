import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A terminal whose reattach retries ran out under a live link starts a fresh round by itself,
/// with no keystroke, Retry or new link, after ``DaemonTerminalSession/gaveUpRetryDelay``. That
/// delay is the backoff's longest step, not the 30 s it was (Leo, 2026-11-21: "intermittent 30s
/// lag/disconnects on ios app on terminal").
@MainActor @Suite struct GaveUpRetryTests {
    static func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theRetryAfterAGiveUpIsNoLongerThanTheBackoffsLastStep() {
        let last = DaemonTerminalSession.defaultReattachBackoff.last ?? 0
        #expect(DaemonTerminalSession.defaultGaveUpRetryDelay == .milliseconds(Int64(last * 1000)))
        #expect(DaemonTerminalSession.defaultGaveUpRetryDelay < .seconds(30))
    }

    @Test func aSessionThatGaveUpAttachesAgainOnItsOwn() async throws {
        let daemon = FakeTerminalDaemon()
        let channels = ChannelLog()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        defer { session.stop() }
        session.start { _ in }
        try await Self.waitUntil { session.isAttached }

        // Every reattach fails on a short backoff: the round gives up.
        daemon.failNextAttaches = 100
        session.reattachBackoff = [0.02, 0.02]
        session.gaveUpRetryDelay = .milliseconds(200)
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await Self.waitUntil {
            if case .failed = session.connectionState { true } else { false }
        }
        if case .failed = session.connectionState {} else {
            Issue.record("the round never gave up: \(session.connectionState)")
        }

        // The Mac answers again; nobody types and no new link comes.
        daemon.failNextAttaches = 0
        try await Self.waitUntil { session.isAttached }
        #expect(session.isAttached, "a session that gave up never attached again by itself")
    }
}
