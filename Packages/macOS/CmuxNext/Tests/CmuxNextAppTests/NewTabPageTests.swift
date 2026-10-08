import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The new tab page (#16620): which kind it starts on, what a terminal
/// choice types, and that every entry point comes from one action.
@Suite struct NewTabPageTests {
    @Test func itStartsReadyForAgentChatRegardlessOfTheOpeningTab() {
        #expect(NewTabPage.kind(selectedID: "surface-1", selectedKind: .pty) == .agent)
        #expect(NewTabPage.kind(selectedID: "surface-2", selectedKind: .browser) == .agent)
        #expect(NewTabPage.kind(selectedID: LocalBrowserTab.prefix + "a", selectedKind: nil) == .agent)
        #expect(NewTabPage.kind(selectedID: "tab_agent", selectedKind: .conversation) == .agent)
        #expect(NewTabPage.kind(selectedID: nil, selectedKind: nil) == .agent)
    }

    /// Cmd-T from any tab shows the field empty, with its placeholder: the source tab's folder
    /// (`~` from a terminal in the home folder) or URL is never typed into it. The folder a chat
    /// or terminal opened from the page starts in stays the source tab's.
    @MainActor @Test func theFieldStartsEmptyFromEverySourceTab() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let home = NSHomeDirectory()
        let terminal = TabModel(TabSnapshot(surface: 5, kind: .pty, title: "zsh", cwd: home))
        let project = TabModel(TabSnapshot(surface: 6, kind: .pty, title: "zsh", cwd: home + "/code/app"))
        let browser = TabModel(TabSnapshot(surface: 7, kind: .browser, title: "Vite", url: "https://vite.dev/guide/", cwd: home))
        for source in [terminal, project, browser] {
            let page = NewTabPage.page(services, selected: source)
            #expect(page.location == nil, "the field of a page opened from \(source.kind) starts empty")
            #expect(page.cwd == source.cwd, "the page keeps the source tab's folder for what it opens")
        }
        #expect(NewTabPage.page(services, selected: nil).location == nil)
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
