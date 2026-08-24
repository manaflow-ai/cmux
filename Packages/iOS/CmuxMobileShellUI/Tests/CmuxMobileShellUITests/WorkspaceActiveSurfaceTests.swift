import Testing
import CmuxMobileShellModel
@testable import CmuxMobileShellUI

@Suite struct WorkspaceActiveSurfaceTests {
    @Test func browserTakesPrecedenceOverTerminal() {
        #expect(WorkspaceActiveSurface.derive(
            hasActiveBrowser: true
        ) == .browser)
    }

    @Test func terminalIsDefaultSurface() {
        #expect(WorkspaceActiveSurface.derive(
            hasActiveBrowser: false
        ) == .terminal)
    }

    @Test func explicitMacSurfaceIsBelowBrowserAndAboveTerminal() {
        let surface = MobileSurfacePreview(id: "surface", kind: .markdown, title: "README")
        #expect(WorkspaceActiveSurface.derive(
            hasActiveBrowser: false,
            selectedMacSurface: surface
        ) == .macSurface(surface))
        #expect(WorkspaceActiveSurface.derive(
            hasActiveBrowser: true,
            selectedMacSurface: surface
        ) == .browser)
    }

    @Test func browserStreamActivatesWhenNoLocalBrowserIsOpen() {
        #expect(WorkspaceActiveSurface.derive(
            hasActiveBrowser: false,
            hasActiveBrowserStream: true
        ) == .browserStream)
    }

    @Test func browserStreamOverlaysASelectedMacSurface() {
        let surface = MobileSurfacePreview(id: "surface", kind: .markdown, title: "README")
        #expect(WorkspaceActiveSurface.derive(
            hasActiveBrowser: false,
            hasActiveBrowserStream: true,
            selectedMacSurface: surface
        ) == .browserStream)
    }

    @Test func simulatorStreamActivatesWhenNoBrowserSurfaceIsOpen() {
        #expect(WorkspaceActiveSurface.derive(
            hasActiveBrowser: false,
            hasActiveBrowserStream: false,
            hasActiveSimulatorStream: true
        ) == .simulatorStream)
    }

    @Test func simulatorStreamOverlaysASelectedMacSurface() {
        let surface = MobileSurfacePreview(id: "surface", kind: .markdown, title: "README")
        #expect(WorkspaceActiveSurface.derive(
            hasActiveBrowser: false,
            hasActiveBrowserStream: false,
            hasActiveSimulatorStream: true,
            selectedMacSurface: surface
        ) == .simulatorStream)
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
