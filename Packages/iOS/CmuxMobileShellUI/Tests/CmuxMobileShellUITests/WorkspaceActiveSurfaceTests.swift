import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceActiveSurfaceTests {
    @Test func browserTakesPrecedenceOverTerminal() {
        #expect(WorkspaceActiveSurface.derive(hasActiveBrowser: true) == .browser)
    }

    @Test func terminalIsDefaultSurface() {
        #expect(WorkspaceActiveSurface.derive(hasActiveBrowser: false) == .terminal)
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
