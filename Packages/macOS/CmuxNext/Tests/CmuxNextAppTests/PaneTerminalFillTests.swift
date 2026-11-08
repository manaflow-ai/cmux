import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTerminal
import Testing

/// A split's new terminal pane (Cmd-D, Cmd-Shift-D) has no surface in the key's frame (`AfterKeyFrameGate`), and its
/// surface draws a few frames later: until then the pane's content area shows. It painted the window's surface color,
/// not the terminal's, so the new pane flashed one flat color that was neither the terminal before the key nor the one
/// after (the split scale bench's blank frames, split_down and bottom_open, 1 pane, empty terminal). Under a terminal
/// tab the content area now paints the terminal's own background until the terminal's host shows and paints it (Leo:
/// "content never blank"); then the pane goes back to its surface color under the host, so a translucent terminal
/// background is not painted twice.
@MainActor @Suite(.serialized) struct PaneTerminalFillTests {
    @Test func aPaneShowingATerminalTabPaintsTheTerminalsBackground() throws {
        // An opaque window with no picture: the panes paint their content area.
        try #require(ThemeScope.app.backdropSelection == nil)
        try #require(WindowBackdrop(ThemeScope.app.tokens).panesPaintBackground)
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("term"), title: "zsh")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.themeDidChange()
        let surface = pane.performWithTheme { Palette.surfaceBackground.cgColor }
        let terminal = pane.performWithTheme { Palette.surfaceOverride(.terminal) }?.cgColor ?? GhosttyRuntime.shared.backgroundColor.cgColor
        #expect(pane.contentHost.layer?.backgroundColor == surface, "no terminal tab: the surface color")

        pane.awaitedTerminal = AwaitedTerminal(theme: nil) // the selected tab is a terminal, its surface not made yet
        #expect(pane.contentHost.layer?.backgroundColor == terminal, "the empty new terminal pane shows the terminal's color")

        pane.themeDidChange() // a theme change keeps it
        #expect(pane.contentHost.layer?.backgroundColor == terminal)

        pane.awaitedTerminal = nil // its host shows and paints the terminal's background itself
        #expect(pane.contentHost.layer?.backgroundColor == surface, "one owner of the terminal's background")
    }
}
