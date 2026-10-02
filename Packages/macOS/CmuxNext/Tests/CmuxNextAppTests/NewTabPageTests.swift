import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import Testing
@testable import CmuxNextApp

/// The new tab page (#16620): which kind it starts on, what a terminal
/// choice types, and that every entry point comes from one action.
@Suite struct NewTabPageTests {
    @Test func itStartsOnTheKindOfTheTabItOpensFrom() {
        #expect(NewTabPage.kind(selectedID: "surface-1", selectedKind: .pty) == .terminal)
        #expect(NewTabPage.kind(selectedID: "surface-2", selectedKind: .browser) == .browser)
        #expect(NewTabPage.kind(selectedID: LocalBrowserTab.prefix + "a", selectedKind: nil) == .browser)
        #expect(NewTabPage.kind(selectedID: LocalAgentTab.prefix + "a", selectedKind: nil) == .agent)
        #expect(NewTabPage.kind(selectedID: nil, selectedKind: nil) == .terminal)
    }

    @Test func aTerminalChoiceRunsOneTrimmedCommandOrNothing() {
        #expect(NewTabPage.command("  bun dev ") == .some("bun dev\n"))
        #expect(NewTabPage.command(" \n") == .some(nil))
        #expect(NewTabPage.command("") == .some(nil))
        // The field is one line; a forged multi-line text runs nothing.
        #expect(NewTabPage.command("ls\nrm -rf x") == .none)
        #expect(NewTabPage.command("ls\rpwd") == .none)
    }

    /// Each kind's chord on the page is its New action's, so editing one
    /// there or in Settings changes the same binding.
    @Test func eachKindNamesACatalogAction() {
        for kind in AgentPaneTabKind.allCases {
            let id = try? #require(NewTabPage.newActions[kind])
            #expect(ActionCatalog.all.contains { $0.id == id })
        }
    }

    @Test func theActionReachesPaletteKeyboardMenuAndCLI() throws {
        let action = try #require(ActionCatalog.all.first { $0.id == NewTabPage.action })
        #expect(action.cliName == "tab new-page")
        #expect(action.surfaces.isSuperset(of: [.palette, .keyboard, .contextMenu]))
        #expect(action.defaultShortcut == nil)
        #expect(ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .newTab)).contains(NewTabPage.action))
    }
}
