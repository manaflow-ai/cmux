import Testing
@testable import CmuxMobileTerminal

/// termfix-r13 D5 (T-INPUT-17): with the Mac down, Send keeps the command in
/// the composer, marked unsent, instead of clearing it into a queue that
/// ran it 15 minutes later.
@Suite struct ComposerSendGateTests {
    @Test func sendGoesOnlyToAnAttachedTerminal() {
        #expect(TerminalConnectionState.attached.composerNotSentNotice == nil)
        #expect(TerminalConnectionState.offline(mac: "mini").composerNotSentNotice
            == "Not sent: mini is offline. Send again when it's back.")
        // A reattach (a blip) is not refused: the send waits in the session's bounded hold.
        #expect(TerminalConnectionState.reattaching(mac: "mini").composerNotSentNotice == nil)
        // A first attach: sent through the session's short hold, not refused.
        #expect(TerminalConnectionState.connecting(mac: nil).composerNotSentNotice == nil)
    }

    @Test func droppedKeysAreSaidOnce() {
        #expect(TerminalConnectionState.inputNotSentNotice == "Keys typed while your Mac was unreachable were not sent.")
        // An offline state is not attached, and its card says so without a spinner.
        #expect(!TerminalConnectionState.offline(mac: nil).isAttached)
        #expect(TerminalConnectionState.offline(mac: nil).label == "Your Mac is offline")
        #expect(!TerminalConnectionState.offline(mac: nil).showsProgress)
        #expect(TerminalConnectionState.reattaching(mac: nil).showsProgress)
    }
}

#if os(iOS)
import CmuxMobileArtifacts
import Foundation

/// A composer send over a blip goes into the session's hold; when the hold drops it (a real
/// outage), the text comes back to the composer with the notice, so nothing typed is lost.
@MainActor
@Suite struct ComposerHeldSendTests {
    @MainActor
    final class StubSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    @Test func aSendDroppedAfterABlipComesBackToTheComposer() {
        let model = TerminalModel(session: StubSession(), artifactSource: MockArtifactSource(), title: "held")
        model.ingest(.connection(.reattaching(mac: "mini")))
        model.composerText = "make test"
        model.send()
        #expect(model.composerText.isEmpty)
        #expect(model.composerNotice == nil, "a blip says nothing")
        model.ingest(.inputNotSent(bytes: 10))
        #expect(model.composerText == "make test")
        #expect(model.composerNotice == TerminalConnectionState.inputNotSentNotice)
    }

    @Test func aSendWhileAttachedIsNeverPutBack() {
        let model = TerminalModel(session: StubSession(), artifactSource: MockArtifactSource(), title: "held")
        model.ingest(.connection(.attached))
        model.composerText = "ls"
        model.send()
        model.ingest(.inputNotSent(bytes: 3))
        #expect(model.composerText.isEmpty)
    }
}
#endif

#if os(iOS)
/// Codex review of #41898 (F3): a refusal that comes inside `send` itself (the hold was full
/// or already dropped) leaves the composer's text where it was.
@MainActor
@Suite struct ComposerRefusedInSendTests {
    @Test func aRefusalDuringSendKeepsTheText() {
        let model = TerminalModel(session: ComposerHeldSendTests.StubSession(), artifactSource: MockArtifactSource(), title: "held")
        model.ingest(.connection(.reattaching(mac: "mini")))
        model.composerText = "make test"
        model.heldComposerSend = ("make test", ProcessInfo.processInfo.systemUptime)
        // What the session says while `send` hands it the text.
        model.ingest(.inputNotSent(bytes: 10))
        #expect(model.composerSendRefused)
        #expect(model.composerText == "make test")
        #expect(model.composerNotice == TerminalConnectionState.inputNotSentNotice)
    }
}
#endif
