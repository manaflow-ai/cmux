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

    /// Each kind opens directly from the keyboard (#16620). The chords are
    /// Command chords nothing else owns: not another action, not a chord a
    /// page keeps, and not one of Ghostty's default keybinds, so a terminal
    /// never loses a key it reads.
    @Test func eachKindHasItsOwnChord() {
        let chords: [ActionID: Shortcut] = [
            "newSurface": Shortcut("t", modifiers: [.control, .shift, .command]),
            "openBrowser": Shortcut("l", modifiers: [.command, .shift]),
            "palette.newAgentChat": Shortcut("i", modifiers: [.command, .shift]),
        ]
        // Ghostty's macOS defaults near these keys: scroll to selection,
        // write screen file, select all, inspector, clear screen.
        let ghostty: Set<Shortcut> = [
            Shortcut("j", modifiers: [.command]), Shortcut("j", modifiers: [.command, .shift]),
            Shortcut("a", modifiers: [.command]), Shortcut("i", modifiers: [.command, .option]),
            Shortcut("k", modifiers: [.command]),
        ]
        for (id, chord) in chords {
            let action = ActionCatalog.all.first { $0.id == id }
            #expect(action?.defaultShortcut == chord, "\(id)")
            #expect(action?.surfaces.contains(.keyboard) == true, "\(id)")
            #expect(ActionCatalog.all.filter { $0.defaultShortcut == chord }.map(\.id) == [id])
            #expect(chord.modifiers.contains(.command))
            #expect(!BrowserChordTable.chromeReserved.contains(chord), "\(id)")
            #expect(!ghostty.contains(chord), "\(id)")
        }
    }
}
