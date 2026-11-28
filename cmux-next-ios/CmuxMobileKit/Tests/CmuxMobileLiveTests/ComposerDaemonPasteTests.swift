// TerminalModel is iOS only: these run in the kit's iOS simulator step.
#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The composer's Send on a Mac terminal (Leo: "it also just didnt send my s*** when i put it at the
/// bottoma"): the whole draft goes as one `send {text, paste:true, submit:true}`, which the daemon
/// brackets by the terminal's own mode 2004 and submits in the same request, never as the mirror's
/// paste plus a separate Enter 60 ms later.
@MainActor @Suite struct ComposerDaemonPasteTests {
    /// A multi-KB, multi-line draft like Leo's (two pasted blocks and a typed tail).
    static let draft = String(repeating: "a pasted line of the draft, long enough to matter\n", count: 120)
        + "re if its like the connection is actually working"

    /// `pasteSubmit`: a daemon of today, listing `send-key-v1` and `send-expect-agent-v1` (false: one
    /// older than both). `projected`: the screen drives the session through the projection wrapper,
    /// as every terminal does by default (#49901). `attached`: wait for the first attach.
    private func rig(
        pasteSubmit: Bool,
        channels: ChannelLog = ChannelLog(),
        clock: (() -> TimeInterval)? = nil,
        projected: Bool = false,
        attached: Bool = true
    ) async throws -> (FakeTerminalDaemon, DaemonTerminalSession, TerminalModel) {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        daemon.pasteSubmit = pasteSubmit
        daemon.sendKeys = pasteSubmit
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        if let clock { session.now = clock }
        let screen: any TerminalSession = projected ? TerminalProjectingSession(inner: session) : session
        let model = TerminalModel(session: screen, artifactSource: UnavailableArtifactSource(), title: "composer-paste")
        if attached {
            session.start { _ in }
            try await waitUntil { session.isAttached }
        }
        return (daemon, session, model)
    }

    private func sends(_ daemon: FakeTerminalDaemon) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == "send" }
    }

    @Test func sendGoesAsOneDaemonPasteWithSubmit() async throws {
        let (daemon, session, model) = try await rig(pasteSubmit: true)
        defer { session.stop() }
        #expect(Self.draft.utf8.count > 6000)
        model.composerText = Self.draft
        model.send()
        try await waitUntil { !sends(daemon).isEmpty }
        // Past the mirror's Enter delay (several times over): no separate Return follows. A second request ends
        // the wait at once, so a stray Enter fails here and a quiet daemon is not waited on past the window.
        try await waitWhile(for: ComposerSubmit.enterDelay * 5) { sends(daemon).count == 1 }
        let sent = sends(daemon)
        #expect(sent.count == 1, "one request, no separate Enter: \(sent)")
        let request = try #require(sent.first)
        #expect(request["surface"] as? Int == 7)
        #expect(request["text"] as? String == Self.draft)
        #expect(request["paste"] as? Bool == true)
        #expect(request["submit"] as? Bool == true)
        #expect(request["bytes"] == nil)
        #expect(model.composerText.isEmpty)
        #expect(model.composerNotice == nil)
    }

    /// Keys typed before the Send reach the terminal first, in their own request.
    @Test func keysQueuedBeforeTheSendGoFirst() async throws {
        let (daemon, session, model) = try await rig(pasteSubmit: true)
        defer { session.stop() }
        session.send(Data("ab".utf8))
        model.composerText = Self.draft
        model.send()
        try await waitUntil { sends(daemon).count >= 2 }
        let sent = sends(daemon)
        #expect(sent.count == 2)
        #expect(sent.first?["bytes"] as? String == Data("ab".utf8).base64EncodedString())
        #expect(sent.last?["text"] as? String == Self.draft)
        #expect(sent.last?["submit"] as? Bool == true)
    }

    /// An older daemon (no `send-expect-agent-v1`) ignores `submit`: the session declines, and the
    /// composer keeps the mirror's paste and Enter.
    @Test func anOlderDaemonKeepsTheMirrorPath() async throws {
        let (daemon, session, model) = try await rig(pasteSubmit: false)
        defer { session.stop() }
        model.composerText = Self.draft
        // No page here: the mirror path has no surface, so nothing reaches the daemon.
        model.send()
        // The daemon records requests in the order the session wrote them: once a key sent after the Send is
        // recorded, anything the Send had put on the wire is too.
        session.send(Data("z".utf8))
        try await waitUntil { sends(daemon).contains { $0["bytes"] != nil } }
        #expect(!sends(daemon).contains { $0["submit"] != nil || $0["text"] != nil })
    }

    // MARK: A send that does not reach the terminal brings the draft back, with no banner.

    /// The daemon answers the paste with an error.
    @Test func aRefusedSendGivesTheDraftBack() async throws {
        let (daemon, session, model) = try await rig(pasteSubmit: true)
        defer { session.stop() }
        daemon.refusesPasteSubmit = true
        model.composerText = Self.draft
        model.send()
        try await waitUntil { model.composerText == Self.draft }
        #expect(model.composerNotice == nil, "the draft comes back with no banner")
        #expect(model.composerText == Self.draft)
    }

    /// Leo, 2026-11-23: "there's like a sort of like double send type thing". The channel fails
    /// after the Send was written and before its answer (a reconnect mid-send): it goes again on
    /// the next channel under the key it got at the tap, which the daemon types once, and the
    /// draft never comes back to be sent a second time.
    @Test func aChannelLostMidSendGoesAgainUnderItsKey() async throws {
        let channels = ChannelLog()
        let (daemon, session, model) = try await rig(pasteSubmit: true, channels: channels, clock: { 1000 })
        defer { session.stop() }
        daemon.unansweredSends = true
        model.composerText = Self.draft
        model.send()
        try await waitUntil { sends(daemon).count == 1 }
        #expect(model.composerText.isEmpty)
        daemon.unansweredSends = false
        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await waitUntil { sends(daemon).count == 2 }
        let sent = sends(daemon)
        #expect(sent.count == 2, "sent again once, after the reattach: \(sent.count)")
        let key = try #require(sent.first?["key"] as? String)
        #expect(sent.map { $0["key"] as? String } == [key, key], "both attempts under the tap's key")
        #expect(sent.allSatisfy { $0["text"] as? String == Self.draft && $0["submit"] as? Bool == true })
        // Answered: sent, nothing comes back.
        try await waitWhile(for: .milliseconds(300)) { model.composerNotice == nil }
        #expect(model.composerNotice == nil)
        #expect(model.composerText.isEmpty)
    }

    /// The daemon answers an error that may have typed it (the text went in, its Return failed):
    /// a resend under its key would write nothing, and putting the draft back invites a second
    /// Send. The person is told it may have been sent, and the composer stays empty.
    @Test func anAmbiguousErrorSaysMaybeSentAndKeepsTheDraftOut() async throws {
        let (daemon, session, model) = try await rig(pasteSubmit: true)
        defer { session.stop() }
        daemon.ambiguousPasteSubmit = true
        model.composerText = Self.draft
        model.send()
        try await waitUntil { model.composerNotice != nil }
        #expect(model.composerNotice == TerminalConnectionState.composerSendMaybeSentNotice)
        #expect(model.composerText.isEmpty)
        #expect(sends(daemon).count == 1, "never sent again")
    }

    /// The terminal screen drives a projected session by default (#49901). Its Send reaches the
    /// daemon as the same one request, never the mirror's paste and a separate Return (the
    /// wrapper did not pass the Send on, so every Send was two: "the text goes through. But then
    /// the send doesn't go through").
    @Test func aProjectedTerminalSendsOneDaemonPasteWithSubmit() async throws {
        let (daemon, session, model) = try await rig(pasteSubmit: true, projected: true)
        defer { session.stop() }
        model.composerText = Self.draft
        model.send()
        try await waitUntil { !sends(daemon).isEmpty }
        try await waitWhile(for: ComposerSubmit.enterDelay * 5) { sends(daemon).count == 1 }
        let sent = sends(daemon)
        #expect(sent.count == 1, "one request, no separate Enter: \(sent)")
        #expect(sent.first?["text"] as? String == Self.draft)
        #expect(sent.first?["submit"] as? Bool == true)
        #expect(sent.first?["key"] is String)
        #expect(model.composerText.isEmpty)
    }

    /// A Send made before the terminal first attached ("if it wasn't connected properly in
    /// time, the send doesn't go through") waits for the attach and goes as one keyed request.
    @Test func aSendBeforeTheFirstAttachWaitsAndGoesAsOne() async throws {
        let (daemon, session, model) = try await rig(pasteSubmit: true, clock: { 1000 }, attached: false)
        defer { session.stop() }
        model.composerText = Self.draft
        model.send()
        #expect(model.composerText.isEmpty)
        #expect(sends(daemon).isEmpty)
        session.start { _ in }
        try await waitUntil { session.isAttached }
        try await waitUntil { !sends(daemon).isEmpty }
        try await waitWhile(for: ComposerSubmit.enterDelay * 5) { sends(daemon).count == 1 }
        let sent = sends(daemon)
        #expect(sent.count == 1, "one request: \(sent)")
        #expect(sent.first?["text"] as? String == Self.draft)
        #expect(sent.first?["submit"] as? Bool == true)
        #expect(sent.first?["key"] is String)
        #expect(model.composerNotice == nil)
    }

    /// Sent during a blip and the Mac offline past the hold: dropped, never typed late, and given back.
    @Test func aSendHeldPastTheHoldGivesTheDraftBack() async throws {
        let channels = ChannelLog()
        var clock: TimeInterval = 1000
        let (daemon, session, model) = try await rig(pasteSubmit: true, channels: channels, clock: { clock })
        defer { session.stop() }
        await channels.last?.close(code: "link_closed", reason: "blip")
        try await waitUntil { !session.isAttached }
        model.composerText = Self.draft
        model.send()
        #expect(model.composerText.isEmpty)
        // The reconnect gives up: the Mac stays offline past the hold.
        session.setMacOffline(true)
        clock += DaemonTerminalSession.inputHoldLimit + 0.5
        session.setMacOffline(false)
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await waitUntil { model.composerText == Self.draft }
        #expect(model.composerNotice == nil, "the draft comes back with no banner")
        #expect(model.composerText == Self.draft)
        #expect(sends(daemon).isEmpty)
    }

    /// A draft bigger than the hold, sent during a blip, is refused inside `send`: the composer keeps it.
    @Test func aDraftBiggerThanTheHoldStaysInTheComposer() async throws {
        let channels = ChannelLog()
        let (_, session, model) = try await rig(pasteSubmit: true, channels: channels, clock: { 1000 })
        defer { session.stop() }
        await channels.last?.close(code: "link_closed", reason: "blip")
        try await waitUntil { !session.isAttached }
        let big = String(repeating: "x", count: DaemonTerminalSession.inputHoldBytes + 1) + "\nend"
        model.composerText = big
        model.send()
        #expect(model.composerText == big)
        #expect(model.composerNotice == nil)
    }

    /// After a drop the session refuses input until it attaches again: a send then stays in the composer.
    @Test func aSendTheSessionRefusesStaysInTheComposer() async throws {
        let channels = ChannelLog()
        let (_, session, model) = try await rig(pasteSubmit: true, channels: channels, clock: { 1000 })
        defer { session.stop() }
        await channels.last?.close(code: "link_closed", reason: "blip")
        try await waitUntil { !session.isAttached }
        // Fills the hold: dropped, and input is refused until the next attach.
        session.send(Data(repeating: UInt8(ascii: "y"), count: DaemonTerminalSession.inputHoldBytes + 1))
        model.composerText = Self.draft
        model.send()
        #expect(model.composerText == Self.draft)
        #expect(model.composerNotice == nil)
    }

    /// Holds while `condition` stays true, for at most `window`: returns early when it turns false.
    private func waitWhile(for window: Duration, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + window
        while condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
#endif
