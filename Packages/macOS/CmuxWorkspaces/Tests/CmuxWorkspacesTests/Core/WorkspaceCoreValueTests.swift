import Testing
@testable import CmuxWorkspaces

@Suite struct SurfaceKindTests {
    /// The kind strings are persisted in session snapshots and compared
    /// against bonsplit tab kinds; the values are a frozen wire format.
    @Test func kindStringsAreFrozenWireValues() {
        #expect(SurfaceKind.terminal.rawValue == "terminal")
        #expect(SurfaceKind.browser.rawValue == "browser")
        #expect(SurfaceKind.markdown.rawValue == "markdown")
        #expect(SurfaceKind.filePreview.rawValue == "filePreview")
        #expect(SurfaceKind.rightSidebarTool.rawValue == "rightSidebarTool")
        #expect(SurfaceKind.agentSession.rawValue == "agentSession")
        #expect(SurfaceKind.project.rawValue == "project")
        #expect(SurfaceKind.extensionBrowser.rawValue == "extensionBrowser")
    }
}

@Suite struct PanelShellActivityStateTests {
    /// Raw values arrive over the control socket and live in session
    /// snapshots; round-tripping must stay stable.
    @Test func rawValuesRoundTrip() {
        #expect(PanelShellActivityState(rawValue: "unknown") == .unknown)
        #expect(PanelShellActivityState(rawValue: "promptIdle") == .promptIdle)
        #expect(PanelShellActivityState(rawValue: "commandRunning") == .commandRunning)
        #expect(PanelShellActivityState(rawValue: "bogus") == nil)
        #expect(PanelShellActivityState.promptIdle.rawValue == "promptIdle")
        #expect(PanelShellActivityState.commandRunning.rawValue == "commandRunning")
    }
}

@Suite struct WorkspacePendingTerminalInputReasonTests {
    /// Parity with the legacy `WorkspacePendingTerminalInputPolicy.timeout(for:)`.
    @Test func configurationCommandTimeoutMatchesLegacyPolicy() {
        #expect(WorkspacePendingTerminalInputReason.configurationCommand.timeout == 3.0)
    }
}
