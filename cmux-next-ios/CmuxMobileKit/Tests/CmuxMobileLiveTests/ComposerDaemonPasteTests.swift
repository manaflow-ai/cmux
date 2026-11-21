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

    private func rig(pasteSubmit: Bool) async throws -> (FakeTerminalDaemon, DaemonTerminalSession, TerminalModel) {
        let daemon = FakeTerminalDaemon()
        daemon.afterAttach = nil
        daemon.pasteSubmit = pasteSubmit
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        let session = DaemonTerminalSession(surface: 7) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let model = TerminalModel(session: session, artifactSource: UnavailableArtifactSource(), title: "composer-paste")
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
        // Past the mirror's 60 ms Enter delay: no separate Return follows.
        try await Task.sleep(for: .milliseconds(300))
        let sent = sends(daemon)
        #expect(sent.count == 1, "one request, no separate Enter: \(sent)")
        let request = try #require(sent.first)
        #expect(request["surface"] as? Int == 7)
        #expect(request["text"] as? String == Self.draft)
        #expect(request["paste"] as? Bool == true)
        #expect(request["submit"] as? Bool == true)
        #expect(request["bytes"] == nil)
        #expect(model.composerText.isEmpty)
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
        try await Task.sleep(for: .milliseconds(300))
        #expect(!sends(daemon).contains { $0["submit"] != nil || $0["text"] != nil })
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
