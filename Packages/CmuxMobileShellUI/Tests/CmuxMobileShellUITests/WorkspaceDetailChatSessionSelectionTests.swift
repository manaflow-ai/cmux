import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceDetailChatSessionSelectionTests {
    @Test func openableByTerminalKeepsLiveSessionFromBeingShadowedByEndedRecord() {
        let terminalID = "terminal-1"
        let live = ChatSessionDescriptor(
            id: "live",
            agentKind: .claude,
            terminalID: terminalID,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 10)
        )
        let ended = ChatSessionDescriptor(
            id: "ended",
            agentKind: .claude,
            terminalID: terminalID,
            state: .ended,
            lastActivityAt: Date(timeIntervalSince1970: 20)
        )

        let result = WorkspaceDetailView.openableByTerminal([ended, live])

        #expect(result.map(\.id) == ["live"])
    }
}
