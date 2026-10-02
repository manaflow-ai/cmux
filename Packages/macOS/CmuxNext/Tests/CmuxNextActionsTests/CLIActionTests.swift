@testable import CmuxNextActions
import Testing

/// Actions the `cmux` CLI offers by name (`ActionDescriptor.cli`,
/// plans/cmux-next/state-ownership.md 5).
@Suite struct CLIActionTests {
    @Test func everyCLIActionHasItsOwnCLIName() {
        let cli = ActionCatalog.all.filter(\.cli)
        #expect(cli.count == ActionCatalog.cliActionIDs.count, "an id in cliActionIDs is not in the catalog")
        for descriptor in cli {
            #expect(descriptor.cliName != ActionDescriptor.defaultCLIName(for: descriptor.id), "\(descriptor.id) has no cliName")
            #expect(!descriptor.isDebugOnly, "\(descriptor.id) is debug-only")
        }
        let ids = Set(ActionCatalog.all.map(\.id))
        let unknown = ActionCatalog.cliActionIDs.subtracting(ids)
        #expect(unknown.isEmpty, "unknown: \(unknown.map(\.rawValue).sorted())")
    }

    @Test func guiOnlyActionsStayOffTheCLI() {
        let byID = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })
        for id: ActionID in ["focusLeft", "commandPalette", "toggleSidebar", "browserZoomIn", "commandPaletteNext"] {
            #expect(byID[id]?.cli == false, "\(id)")
        }
        for id: ActionID in ["newTab", "renameWorkspace", "closeTab", "tab.focus", "screen.new", "tabGroup.create", "newWindow"] {
            #expect(byID[id]?.cli == true, "\(id)")
        }
    }

    /// Connect and Remove are network round trips the CLI waits for: `cli`,
    /// `waitsForResult`, and the 40 s result deadline (the CLI reads for 45 s).
    @Test func accountsConnectAndRemoveRunFromTheCLIAndWaitForTheResult() {
        let byID = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })
        for id: ActionID in ["accounts.connect", "accounts.remove"] {
            #expect(byID[id]?.cli == true, "\(id)")
            #expect(byID[id]?.waitsForResult == true, "\(id)")
        }
        for id: ActionID in ["accounts.show", "accounts.refresh", "accounts.reauthenticate", "quit", "history.reopen"] {
            #expect(byID[id]?.cli == true, "\(id)")
        }
        #expect(ActionDescriptor.resultDeadline == .seconds(40))
    }
}
