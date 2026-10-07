import CmuxNextActions
import Testing

/// One palette: Cmd-Shift-P is the only palette and Cmd-K only clears the
/// terminal (plans: Lawrence x Leo call 2026-10-06, section E).
@Suite struct OnePaletteShortcutTests {
    private let cmdK = Shortcut("k", modifiers: [.command])
    private var byID: [ActionID: ActionDescriptor] {
        Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })
    }

    @Test func cmdKOnlyClearsTheTerminal() throws {
        let owners = ActionCatalog.all.filter { $0.defaultShortcut == cmdK }.map(\.id)
        #expect(owners == ["terminal.clear"])
        let clear = try #require(byID["terminal.clear"])
        #expect(clear.surfaces.contains(.keyboard))
        #expect(clear.requires.contains(.terminalFocused))
    }

    @Test func chatSearchLivesInTheCommandPalette() throws {
        #expect(byID["agentPane.searchChats"] == nil, "no chat-only palette")
        let search = try #require(byID["agentChats.search"])
        #expect(search.surfaces.contains(.palette))
    }

    @Test func actionsThatGaveUpCmdKStayInThePalette() {
        for id: ActionID in ["markdownLink", "simulatorToggleSoftwareKeyboard"] {
            #expect(byID[id]?.surfaces.contains(.palette) == true, "\(id)")
        }
    }
}
