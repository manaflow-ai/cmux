import CmuxNextControl
import Darwin
import Testing

/// SignalRelay names who sent a relayed signal: a fresh-home launch smoke on the signing Mac ended at launch by a
/// SIGTERM that no crash report or log line traced to anyone (`quit origin=signal`, 2026-11-25), so the quit line
/// now carries the sender's pid, parent and executable.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SignalRelaySenderTests {
    @Test func aSignalThisProcessSendsNamesThisProcess() async throws {
        var delivered = false
        let relay = SignalRelay(signals: [SIGUSR2]) { _ in delivered = true }
        defer { relay.cancel() }
        #expect(kill(getpid(), SIGUSR2) == 0)
        for _ in 0..<200 where !delivered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(delivered)
        #expect(SignalRelay.lastSender(of: SIGUSR2) == getpid())
        let line = SignalRelay.senderDescription(of: SIGUSR2)
        #expect(line.contains("pid \(getpid())"))
        #expect(line.contains("parent \(getppid())"))
    }

    @Test func aSignalNobodySentNamesNobody() {
        #expect(SignalRelay.lastSender(of: SIGWINCH) == nil)
        #expect(SignalRelay.senderDescription(of: SIGWINCH) == "sender unknown")
    }
}
