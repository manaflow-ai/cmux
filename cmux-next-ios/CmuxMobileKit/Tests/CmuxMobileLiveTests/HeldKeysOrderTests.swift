import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo, 2026-11-24, back from another app: "The like multi-second long reattach where like the
/// entire thing is somehow grayed out and I can't interact with anything at all."
///
/// The app comes back to the foreground with the link down, and the reattach takes longer than
/// the old 10 s hold. Three keys typed over it are accepted at once (nothing says "not sent",
/// nothing goes yet) and reach the Mac's terminal after the attach, once each, in order.
/// On feat-cmux-next before this change the attach dropped them ("not sent"): they were older
/// than 10 s when it landed.
@MainActor @Suite struct HeldKeysOrderTests {
    @Test func threeKeysTypedWhileTheLinkIsDownAreAcceptedAtOnceAndGoInOrderAfterTheAttach() async throws {
        let daemon = FakeTerminalDaemon()
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let channels = ChannelLog()
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        defer { session.stop() }
        var clock: TimeInterval = 1000
        session.now = { clock }
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        try await waitUntil { session.isAttached }
        let notSent = { events.contains { if case .inputNotSent = $0 { true } else { false } } }
        let typed = {
            daemon.recorded.filter { $0["cmd"] as? String == "send" }
                .compactMap { ($0["bytes"] as? String).flatMap { Data(base64Encoded: $0) } }
                .reduce(into: Data()) { $0.append($1) }
        }

        // The app went to the background and comes back: the link is down.
        await channels.last?.close(code: "link_closed", reason: "app in the background")
        try await waitUntil { !session.isAttached }

        // Three keys over a 12 s reattach, each taken at once: no notice, nothing sent yet.
        for key in ["a", "b", "c"] {
            session.send(Data(key.utf8))
            #expect(!notSent(), "\(key) was refused while the terminal reconnects")
            #expect(typed().isEmpty, "\(key) went before the attach")
            clock += 6
        }

        session.reconnect()
        try await waitUntil { session.isAttached }
        try await waitUntil { typed() == Data("abc".utf8) }
        for _ in 0..<50 { await Task.yield() }
        #expect(String(decoding: typed(), as: UTF8.self) == "abc", "each key once, in order, after the attach")
        #expect(!notSent(), "the attach dropped keys typed while it reconnected")
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
}
