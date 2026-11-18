import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// An open Go to Workspace (Cmd-P) lists a workspace that appears while it shows (Cmd-Shift-P lists no workspace).
/// The palette read the app's workspace list once, at open: a workspace whose sidebar row showed at the press
/// (a pending row) reached the app's list a moment later, and Cmd-P never listed it until it opened again
/// (CmdPSwitchMovesSidebarSelectionTests failed 2 runs in 3: "Cmd-P lists" two workspaces, not the new one).
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct OpenGoToWorkspaceFollowsTheListTests {
    @MainActor private final class Store: PaletteWorkspaceSource {
        var workspaces = [PaletteWorkspace(id: "a", title: "cmdp-from")]
        var changed: [@MainActor () -> Void] = []
        private final class Token {}

        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
        func followChanges(_ changed: @escaping @MainActor () -> Void) -> AnyObject? {
            self.changed.append(changed)
            return Token()
        }

        func add(_ workspace: PaletteWorkspace) {
            workspaces.append(workspace)
            for change in changed { change() }
        }
    }

    @Test(arguments: ["goToWorkspace"])
    func aWorkspaceAddedWhileThePaletteShowsIsListed(action: String) async throws {
        _ = NSApplication.shared
        let store = Store()
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: PaletteSources(workspaces: store), frecencyPersistence: nil)
        palette.bindRegistryActions()
        defer { palette.closeForTest() }
        _ = registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(arguments: [:], origin: .user))
        await palette.model.settleDeferredLoads()
        palette.model.send(.setQuery("cmdp"))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.item.id == "workspace:a" }, "\(palette.model.rows.map(\.item.id))")

        store.add(PaletteWorkspace(id: "b", title: "cmdp-to"))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.item.id == "workspace:b" }, "\(action): \(palette.model.rows.map(\.item.id))")
    }
}
