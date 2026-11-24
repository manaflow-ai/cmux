import Foundation
import Testing

/// Leo, 2026-11-24: "let's just keep optimistically connecting and reinforcing the connection
/// and sync-ups can be satisfying instead of making the user think they're constsntly suspended
/// in a state of connection limbo". A terminal page keeps its last frame through an outage of
/// any length and says nothing about the link: no "Reattaching…" pill subtitle, no connection
/// chip over the page. Reconnect stays in the page menu. This reads the sources that draw the
/// terminal page and its title pill, so a waiting state put back fails here (it fails on the
/// base this PR replaces, whose pill said "Reattaching…" after 10 s).
@Suite struct TerminalPageNoWaitingStateTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// The files that draw a terminal tab's page, its dock and its title pill.
    static let pageFiles = [
        "CmuxMobileShell/GhosttyTerminalTabContent.swift",
        "CmuxMobileWorkspaces/TerminalTabContent.swift",
        "CmuxMobileWorkspaces/WorkspaceTabsSource.swift",
        "CmuxMobileTerminal/Screen/TerminalTabPage.swift",
        "CmuxMobileTerminal/Screen/TerminalModel.swift",
        "CmuxMobileTerminal/Session/TerminalSession.swift",
        "CmuxMobileTerminal/Composer/TerminalComposer.swift",
    ]

    @Test func theTerminalPageDrawsNoConnectionWaitingState() throws {
        for file in Self.pageFiles {
            let text = try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
            for banned in ["\"Reattaching", "pillSubtitle", "statusSubtitle", "ReattachIndicator", "ConnectionChip("] {
                #expect(!text.contains(banned), "\(file) draws a connection waiting state (\(banned))")
            }
        }
        #expect(!FileManager.default.fileExists(
            atPath: Self.sources.appendingPathComponent("CmuxMobileWorkspaces/ReattachIndicator.swift").path))
    }
}
