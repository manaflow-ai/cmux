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
        #expect(TerminalConnectionState.reattaching(mac: "mini").composerNotSentNotice
            == "Not sent: reconnecting to mini. Send again when it's back.")
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
