import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-24 (item 3): "all the connecting... indicators and the graying out of workspaces,
/// nah let's not do that." A terminal tab whose link is still coming back keeps its usual title
/// pill (no "Connecting…" or "Reattaching…"), and a frame kept from an earlier launch is drawn at
/// full strength, never greyed. A real failure still says so.
@Suite struct TerminalNoWaitingWordsTests {
    @Test func aLinkComingBackPutsNoWordInThePill() {
        #expect(TerminalConnectionState.connecting(mac: "Mac Studio").pillSubtitle == nil)
        #expect(TerminalConnectionState.reattaching(mac: "Mac Studio").pillSubtitle == nil)
        #expect(TerminalConnectionState.failed(message: "daemon channel closed").pillSubtitle == "Can't connect")
        #expect(TerminalConnectionState.attached.pillSubtitle == nil)
    }

    @Test func noCardIsGreyed() {
        for content in [TerminalCardContent.snapshot, .screenText, .savedFrame, .nothing] {
            #expect(content.drawnOpacity == 1, "\(content) drawn at \(content.drawnOpacity)")
        }
    }
}
