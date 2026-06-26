import Testing

@testable import CmuxMobileShellModel

/// Regression coverage for issue #6665: the mobile terminal header must reflect
/// the active surface's live title (the running process), the way the macOS app
/// titles a tab from its foreground program, instead of always showing the
/// static workspace name.
///
/// The header's title decision lives in
/// ``MobileWorkspacePreview/terminalHeaderTitle(selectedTerminalID:)`` so it can
/// be exercised here without standing up the SwiftUI view; the view binds its
/// nav-bar title to exactly this helper.
struct MobileWorkspaceTerminalHeaderTitleTests {
    private func workspace(
        name: String,
        terminals: [MobileTerminalPreview]
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(id: "ws", name: name, terminals: terminals)
    }

    @Test func prefersSelectedTerminalTitleOverWorkspaceName() {
        // The repro: a workspace named "Claude Code" whose terminals run
        // different programs. The header must follow the active terminal.
        let ws = workspace(name: "Claude Code", terminals: [
            MobileTerminalPreview(id: "t1", name: "htop"),
            MobileTerminalPreview(id: "t2", name: "nvim"),
        ])
        #expect(ws.terminalHeaderTitle(selectedTerminalID: "t1") == "htop")
        #expect(ws.terminalHeaderTitle(selectedTerminalID: "t2") == "nvim")
    }

    @Test func unknownOrNilSelectionFallsBackToFirstTerminalTitle() {
        // Mirrors the detail view's `selectedTerminal`: an unmatched or nil
        // selection resolves to the first terminal, not the workspace name.
        let ws = workspace(name: "Claude Code", terminals: [
            MobileTerminalPreview(id: "t1", name: "htop"),
            MobileTerminalPreview(id: "t2", name: "nvim"),
        ])
        #expect(ws.terminalHeaderTitle(selectedTerminalID: "missing") == "htop")
        #expect(ws.terminalHeaderTitle(selectedTerminalID: nil) == "htop")
    }

    @Test func fallsBackToWorkspaceNameWhenNoTerminals() {
        let ws = workspace(name: "Claude Code", terminals: [])
        #expect(ws.terminalHeaderTitle(selectedTerminalID: nil) == "Claude Code")
    }

    @Test func fallsBackToWorkspaceNameWhenActiveTitleBlank() {
        // A blank/whitespace title (no useful surface title yet) yields the
        // workspace name rather than an empty header.
        let ws = workspace(name: "Claude Code", terminals: [
            MobileTerminalPreview(id: "t1", name: "   "),
        ])
        #expect(ws.terminalHeaderTitle(selectedTerminalID: "t1") == "Claude Code")
    }
}
