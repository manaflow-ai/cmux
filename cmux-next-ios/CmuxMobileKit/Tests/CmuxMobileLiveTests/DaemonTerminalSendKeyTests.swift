import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-21: "the send sometimes if it lags, if it wasn't connected
/// properly in time, the send doesn't go through ... there's like a sort of
/// like double send type thing".
///
/// A `send` written just before its channel dropped may or may not have been
/// typed on the Mac. The phone used to drop it and put the text back in the
/// composer ("keys not sent"); a second Send then typed it twice when the
/// first had arrived. A Mac that lists `send-key-v1` takes a key per `send`
/// and types a repeated key once, so the phone sends that batch again once,
/// with the same key, after the reattach. An older Mac keeps today's rule.
@MainActor @Suite struct DaemonTerminalSendKeyTests {
    private func rig(_ daemon: FakeTerminalDaemon) -> (DaemonTerminalSession, ChannelLog) {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        // A fixed clock keeps detached-input expiration out of these tests.
        session.now = { 1000 }
        return (session, channels)
    }

    private func sends(_ daemon: FakeTerminalDaemon) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == "send" }
    }

    private static func notSent(_ events: [TerminalSessionEvent]) -> Bool {
        events.contains { if case .inputNotSent = $0 { true } else { false } }
    }

    @Test func aWrittenSendIsResentOnceWithItsKeyAfterTheReattach() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.sendKeys = true
        daemon.unansweredSends = true
        let (session, channels) = rig(daemon)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }

        session.send(Data("ls\r".utf8))
        try await waitUntil { sends(daemon).count == 1 }
        let first = try #require(sends(daemon).first)
        let key = try #require(first["key"] as? String, "a Mac with send-key-v1 gets a key")
        // The reply never comes: the link drops after the write.
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        daemon.unansweredSends = false
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await waitUntil { sends(daemon).count == 2 }
        // Later keys get a key of their own, and go after the resend on the same ordered lane:
        // once the Mac has them, a second resend would already be on record.
        try await sendMarker("x", session, daemon)

        let all = sends(daemon)
        #expect(all.count == 3, "resent exactly once")
        #expect(all[1]["key"] as? String == key, "the resend carries the first key")
        #expect(all[1]["bytes"] as? String == Data("ls\r".utf8).base64EncodedString())
        #expect(!Self.notSent(events), "nothing goes back to the composer")
        #expect((all[2]["key"] as? String).map { $0 != key } == true)
    }

    /// A resend that fails uncertainly again is not sent a third time: the
    /// screen is told, as before.
    @Test func aResendIsNotRepeatedASecondTime() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.sendKeys = true
        daemon.unansweredSends = true
        let (session, channels) = rig(daemon)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        session.send(Data("ls\r".utf8))
        try await waitUntil { sends(daemon).count == 1 }
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        try await waitUntil { sends(daemon).count == 2 }
        await channels.last?.close(code: "link_closed", reason: "link dropped again")
        try await waitUntil { events.contains(.inputNotSent(bytes: 3)) }
        daemon.unansweredSends = false
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await sendMarker("m", session, daemon)
        #expect(sends(daemon).count == 3, "the batch went twice, then only the marker")
    }

    /// A Mac without `send-key-v1`: no key, and a written batch is never sent
    /// again (today's rule; a resend could run the command twice).
    @Test func anOlderMacKeepsTodaysRule() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.unansweredSends = true
        let (session, channels) = rig(daemon)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        session.send(Data("ls\r".utf8))
        try await waitUntil { sends(daemon).count == 1 }
        #expect(sends(daemon).first?["key"] == nil, "an older Mac gets no key")
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { events.contains(.inputNotSent(bytes: 3)) }
        daemon.unansweredSends = false
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await sendMarker("m", session, daemon)
        #expect(sends(daemon).count == 2, "never sent again: only the marker followed")
    }

    /// Sends `text` after a reattach and waits until the Mac has it: input goes in order on one
    /// lane, so any resend of an earlier batch is on record by then (no sleep as synchronization).
    private func sendMarker(_ text: String, _ session: DaemonTerminalSession, _ daemon: FakeTerminalDaemon) async throws {
        let bytes = Data(text.utf8).base64EncodedString()
        session.send(Data(text.utf8))
        try await waitUntil { sends(daemon).contains { $0["bytes"] as? String == bytes } }
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
