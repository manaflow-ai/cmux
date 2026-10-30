import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Go to Workspace with a `workspace` argument (palette row, `cmux action run`, MCP) switches to a
/// workspace that exists and refuses an id that names none, so a bad id is never a silent success.
@MainActor
@Suite(.paletteRanker)
struct GoToWorkspaceRefusesUnknownTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = [PaletteWorkspace(id: "ws_known", title: "Known")]
        var selected: [String] = []
        func selectWorkspace(id: String) { selected.append(id) }
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    @Test func aKnownWorkspaceIsSelected() {
        _ = NSApplication.shared
        let source = Workspaces()
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: PaletteSources(workspaces: source), frecencyPersistence: nil)
        palette.bindRegistryActions()
        let refusal = registry.capturingTypedRefusal {
            _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: ["workspace": .string("ws_known")]))
        }
        #expect(refusal == nil)
        #expect(source.selected == ["ws_known"])
    }

    @Test func anUnknownWorkspaceIsRefusedAsNotFound() {
        _ = NSApplication.shared
        let source = Workspaces()
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: PaletteSources(workspaces: source), frecencyPersistence: nil)
        palette.bindRegistryActions()
        let refusal = registry.capturingTypedRefusal {
            _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: ["workspace": .string("ws_missing")]))
        }
        #expect(refusal?.isNotFound == true)
        #expect(source.selected.isEmpty)
    }
}
