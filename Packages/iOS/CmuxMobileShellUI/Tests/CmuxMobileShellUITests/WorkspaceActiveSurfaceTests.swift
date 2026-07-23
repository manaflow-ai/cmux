import Testing
import CmuxMobileShellModel
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

    @Test func explicitMacSurfaceIsBelowBrowserAndAboveTerminal() {
        let surface = MobileSurfacePreview(id: "surface", kind: .markdown, title: "README")
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: false,
            hasChosenChatSession: false,
            hasActiveBrowser: false,
            selectedMacSurface: surface
        ) == .macSurface(surface))
        #expect(WorkspaceActiveSurface.derive(
            isChatMode: false,
            hasChosenChatSession: false,
            hasActiveBrowser: true,
            selectedMacSurface: surface
        ) == .browser)
    }

    @Test func chromeReturnRefocusesTheSelectedTerminal() {
        #expect(WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: "terminal-1",
            shouldAutoFocusTerminal: { _ in true },
            isComposerPresented: false
        ) == "terminal-1")
    }

    @Test func chromeReturnStaysSuppressedForChromeDrivenSwitches() {
        #expect(WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: "terminal-1",
            shouldAutoFocusTerminal: { _ in false },
            isComposerPresented: false
        ) == nil)
    }

    @Test func chromeReturnLeavesTheKeyboardWithAnOpenComposer() {
        #expect(WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: "terminal-1",
            shouldAutoFocusTerminal: { _ in true },
            isComposerPresented: true
        ) == nil)
    }

    @Test func chromeReturnWithoutATerminalDoesNothing() {
        #expect(WorkspaceActiveSurface.chromeReturnRefocusTerminalID(
            selectedTerminalID: nil,
            shouldAutoFocusTerminal: { _ in true },
            isComposerPresented: false
        ) == nil)
    }
}
