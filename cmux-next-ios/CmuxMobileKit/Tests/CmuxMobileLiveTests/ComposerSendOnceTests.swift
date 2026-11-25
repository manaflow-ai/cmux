// TerminalModel and the projection are iOS only: these run in the kit's iOS simulator step.
#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive
@testable import CmuxMobileTerminal

/// Leo, 2026-11-21, on the phone's terminal composer: "the send sometimes if it lags, if it wasn't
/// connected properly in time, the send doesn't go through, right? Like because like the text goes
/// through. But then the send doesn't go through."
///
/// Every composer Send to a Mac terminal is one daemon request holding the text and its Return,
/// held through a blip and sent once, never the text and a separate Return a blip can split:
///
/// - through the phone's projection (the default page, Fit to Phone off), which used to drop the
///   daemon route and send through the mirror;
/// - for a one-line draft to a full-screen program, which used to be typed through the mirror and
///   followed by Return 250 ms later (`send-typed-submit-v1`).
@MainActor @Suite struct ComposerSendOnceTests {
    private func rig(
        typedSubmit: Bool = true,
        fullScreen: Bool = false,
        projected: Bool = false,
        channels: ChannelLog = ChannelLog(),
        clock: (() -> TimeInterval)? = nil
    ) async throws -> (FakeTerminalDaemon, DaemonTerminalSession, TerminalModel) {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        daemon.pasteSubmit = true
        daemon.sendKeys = true
        daemon.typedSubmit = typedSubmit
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels.append(channel)
            return DaemonClient(channel: channel)
        }
        if let clock { session.now = clock }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let page: any TerminalSession = projected ? TerminalProjectingSession(inner: session) : session
        let model = TerminalModel(session: page, artifactSource: UnavailableArtifactSource(), title: "composer-send-once")
        if fullScreen { model.ingest(.alternateScreen(true)) }
        return (daemon, session, model)
    }

    private func sends(_ daemon: FakeTerminalDaemon) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == "send" }
    }

    /// The default page projects the Mac's terminal: its Send still goes as one daemon paste with
    /// submit. Red before: the projection answered `sendPasteAndSubmit` with the protocol's
    /// default (false), so the draft went through the mirror (here no page: nothing at all).
    @Test func aProjectedPageSendsOneDaemonPasteWithSubmit() async throws {
        let (daemon, session, model) = try await rig(projected: true)
        defer { session.stop() }
        model.composerText = "re if its like the connection is actually working"
        model.send()
        try await waitUntil { !sends(daemon).isEmpty }
        let sent = sends(daemon)
        #expect(sent.count == 1, "one request: \(sent)")
        #expect(sent.first?["text"] as? String == "re if its like the connection is actually working")
        #expect(sent.first?["paste"] as? Bool == true)
        #expect(sent.first?["submit"] as? Bool == true)
        #expect(sent.first?["key"] as? String != nil)
        #expect(model.composerText.isEmpty)
    }

    /// A one-line draft for a full-screen program (an agent TUI, vim) is typed, not pasted: it goes
    /// as one `send {text, submit:true}` with no paste, the daemon's Return in the same request.
    @Test func aFullScreenOneLineSendIsOneTypedSendWithSubmit() async throws {
        for projected in [false, true] {
            let (daemon, session, model) = try await rig(fullScreen: true, projected: projected)
            defer { session.stop() }
            model.composerText = "/status"
            model.send()
            try await waitUntil { !sends(daemon).isEmpty }
            // Past the mirror's typed Enter delay: no separate Return follows.
            try await waitWhile(for: ComposerSubmit.typedEnterDelay * 2) { sends(daemon).count == 1 }
            let sent = sends(daemon)
            #expect(sent.count == 1, "one request, no separate Return (projected: \(projected)): \(sent)")
            let request = try #require(sent.first)
            #expect(request["text"] as? String == "/status")
            #expect(request["submit"] as? Bool == true)
            #expect(request["paste"] as? Bool != true, "typed, not pasted")
            #expect(request["bytes"] == nil)
            #expect(model.composerText.isEmpty)
        }
    }

    /// Sent while the link is down (a blip): held, and once the terminal is attached again it goes
    /// once, text and Return together.
    @Test func aFullScreenSendDuringABlipGoesOnceAfterTheReattach() async throws {
        let channels = ChannelLog()
        let (daemon, session, model) = try await rig(fullScreen: true, channels: channels, clock: { 1000 })
        defer { session.stop() }
        await channels.last?.close(code: "link_closed", reason: "blip")
        try await waitUntil { !session.isAttached }
        model.composerText = "/status"
        model.send()
        #expect(model.composerText.isEmpty)
        #expect(sends(daemon).isEmpty)
        session.reconnect()
        try await waitUntil { session.isAttached }
        try await waitUntil { !sends(daemon).isEmpty }
        try await waitWhile(for: ComposerSubmit.typedEnterDelay * 2) { sends(daemon).count == 1 }
        let sent = sends(daemon)
        #expect(sent.count == 1, "text and Return in one request, once: \(sent)")
        #expect(sent.first?["text"] as? String == "/status")
        #expect(sent.first?["submit"] as? Bool == true)
        #expect(model.composerNotice == nil)
    }

    /// A daemon without `send-typed-submit-v1` would write Return right behind the typed text, inside
    /// an agent's paste-burst window: the session declines and the screen keeps the mirror's path.
    @Test func aDaemonWithoutTypedSubmitKeepsTheMirrorPath() async throws {
        let (daemon, session, model) = try await rig(typedSubmit: false, fullScreen: true)
        defer { session.stop() }
        model.composerText = "/status"
        model.send()
        // Requests are recorded in the order the session wrote them: once a later key is in, so is the Send's.
        session.send(Data("z".utf8))
        try await waitUntil { sends(daemon).contains { $0["bytes"] != nil } }
        #expect(!sends(daemon).contains { $0["submit"] != nil || $0["text"] != nil })
    }

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
