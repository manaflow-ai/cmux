import CmuxNextActions
import CmuxNextDaemon
import Testing
@testable import CmuxNextApp

/// Cmd-T opens a tab of the focused pane's kind (user decision 2026-09-30):
/// a browser tab in a browser pane, a terminal tab in a terminal pane.
@Suite struct NewTabKindTests {
    @Test func aBrowserPaneGetsABrowserTabOnTheSameEngine() {
        #expect(NewTabKind.resolve(selectedKind: .browser, engine: "cef", isLocalBrowser: false) == .browser(engine: "cef"))
        #expect(NewTabKind.resolve(selectedKind: .browser, engine: "webkit", isLocalBrowser: false) == .browser(engine: "webkit"))
        // A session-local browser tab (no daemon tab) is a browser too.
        #expect(NewTabKind.resolve(selectedKind: nil, engine: nil, isLocalBrowser: true) == .browser(engine: nil))
    }

    @Test func terminalAndEmptyPanesGetATerminalTab() {
        #expect(NewTabKind.resolve(selectedKind: .pty, engine: nil, isLocalBrowser: false) == .terminal)
        #expect(NewTabKind.resolve(selectedKind: nil, engine: nil, isLocalBrowser: false) == .terminal)
    }

    /// One action owns Cmd-T for every entry point (keyboard, palette,
    /// menu, CLI `tab new`); New Terminal Tab keeps its CLI and button.
    @Test func cmdTBelongsToTheSameKindAction() {
        let cmdT = Shortcut("t", modifiers: [.command])
        let owners = ActionCatalog.all.filter { $0.defaultShortcut == cmdT }.map(\.id)
        #expect(owners == ["newTab.sameKind"])
        let action = ActionCatalog.all.first { $0.id == "newTab.sameKind" }
        #expect(action?.cliName == "tab new")
        #expect(action?.surfaces.contains(.palette) == true)
        #expect(ActionCatalog.all.first { $0.id == "newSurface" }?.cliName == "tab new-terminal")
    }
}
