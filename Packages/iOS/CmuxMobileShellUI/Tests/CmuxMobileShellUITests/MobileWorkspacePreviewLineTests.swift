#if os(iOS)
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

/// The row shows `name` as its title and `previewLine` directly underneath, so a
/// fallback that resolves to the title paints the same string twice. Workspaces
/// opened at `$HOME` are the common case: the workspace and its first terminal
/// are both named "~", so every such row renders "~" over "~" and the list stops
/// telling rows apart.
@MainActor
@Suite struct MobileWorkspacePreviewLineTests {
    @Test func previewLineIsEmptyWhenTheTerminalFallbackRepeatsTheTitle() {
        let workspace = MobileWorkspacePreview(
            id: "home-workspace",
            name: "~",
            terminals: [MobileTerminalPreview(id: "terminal-1", name: "~")]
        )

        #expect(workspace.previewLine.isEmpty)
    }

    @Test func previewLineIsEmptyWhenTheWorkspaceHasNoTerminals() {
        let workspace = MobileWorkspacePreview(
            id: "empty-workspace",
            name: "~",
            terminals: []
        )

        #expect(workspace.previewLine.isEmpty)
    }

    @Test func previewLineKeepsATerminalNameThatDiffersFromTheTitle() {
        let workspace = MobileWorkspacePreview(
            id: "dev-workspace",
            name: "goldberg",
            terminals: [MobileTerminalPreview(id: "terminal-1", name: "vite dev")]
        )

        #expect(workspace.previewLine == "vite dev")
    }

    @Test func previewLinePrefersRemoteActivityOverTheFallback() {
        let workspace = MobileWorkspacePreview(
            id: "active-workspace",
            name: "~",
            previewText: "Claude is waiting for your input",
            terminals: [MobileTerminalPreview(id: "terminal-1", name: "~")]
        )

        #expect(workspace.previewLine == "Claude is waiting for your input")
    }

    @Test func accessibilitySummaryOmitsTheEmptyPreviewLine() {
        let workspace = MobileWorkspacePreview(
            id: "home-workspace",
            name: "~",
            terminals: [MobileTerminalPreview(id: "terminal-1", name: "~")]
        )

        let summary = workspace.accessibilitySummary(connectionStatus: .connected)

        // An empty preview must drop out of the spoken summary entirely rather
        // than leave VoiceOver an empty element between two separators.
        #expect(!summary.contains(", ,"))
        #expect(!summary.hasPrefix(", "))
    }
}
#endif
