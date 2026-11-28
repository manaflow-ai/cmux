@testable import CmuxNextControl
import Darwin
import Testing

/// SignalRelay names who sent a relayed signal: a fresh-home launch smoke on the signing Mac ended at launch by a
/// SIGTERM that no crash report or log line traced to anyone (`quit origin=signal`, 2026-11-25), so the quit line
/// now carries the sender's pid.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SignalRelaySenderTests {
    @Test func aSignalThisProcessSendsNamesThisProcess() async throws {
        var delivered = false
        let relay = SignalRelay(signals: [SIGUSR2]) { _ in delivered = true }
        defer { relay.cancel() }
        #expect(kill(getpid(), SIGUSR2) == 0)
        for _ in 0..<200 where !delivered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(delivered)
        #expect(SignalRelay.lastSender(of: SIGUSR2) == getpid())
        #expect(SignalRelay.senderDescription(of: SIGUSR2) == "sender pid \(getpid())")
    }

    /// One record holds the signal and its sender, so a signal never reads another's sender (an action
    /// interrupted by a second signal's used to leave them mixed across two stores).
    @Test func aRecordKeepsItsSignalAndSenderTogether() {
        for (signal, sender) in [(SIGTERM, Int32(77)), (SIGINT, Int32.max), (SIGHUP, Int32(0))] {
            let record = SignalRelay.record(signal: signal, sender: sender)
            #expect(Int32(truncatingIfNeeded: record >> 32) == signal)
            #expect(Int32(truncatingIfNeeded: record) == sender)
        }
    }

    @Test func aSignalNobodySentNamesNobody() {
        #expect(SignalRelay.lastSender(of: SIGWINCH) == nil)
        #expect(SignalRelay.senderDescription(of: SIGWINCH) == "sender unknown")
    }
}
