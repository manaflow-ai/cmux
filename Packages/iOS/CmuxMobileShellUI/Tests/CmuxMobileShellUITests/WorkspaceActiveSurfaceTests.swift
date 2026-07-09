import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceActiveSurfaceTests {
    @Test func chatTakesPrecedenceOverBrowserWhenSessionIsChosen() {
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: true,
            hasChosenChatSession: true,
            hasActiveBrowser: true
        ) == .chat)
    }

    @Test func browserTakesPrecedenceWhenChatHasNoChosenSession() {
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: true,
            hasChosenChatSession: false,
            hasActiveBrowser: true
        ) == .browser)
    }

    @Test func terminalIsDefaultSurface() {
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: false,
            hasChosenChatSession: false,
            hasActiveBrowser: false
        ) == .terminal)
    }
}
