import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// HOT PATH AUDIT frames (workspace-switch): Go to Workspace with a `workspace` argument (a palette row, `cmux action
/// run`, MCP, an agent) checks the id by one lookup. It built the whole Go to Workspace list first (every workspace of
/// every machine: its shown name, all its tabs, its group, its subagent id) only to find that one id: O(session) in
/// the switch's own turn, about 2-4 ms of a light session's switch on the fleet (anim-perf `ws-switch` sample, job
/// 26f0c08e8020a3ce0d8fe677: `WorkspaceSource.workspaces.getter` 35 of 377 busy ms), more in STRESS.
@MainActor
@Suite(.paletteRanker)
struct GoToWorkspaceBuildsNoListTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        let known: Set<String>
        private(set) var listBuilds = 0
        private(set) var selected: [String] = []
        init(_ known: Set<String>) { self.known = known }
        var workspaces: [PaletteWorkspace] {
            listBuilds += 1
            return known.sorted().map { PaletteWorkspace(id: $0, title: $0) }
        }
        func hasWorkspace(id: String) -> Bool { known.contains(id) }
        func selectWorkspace(id: String) { selected.append(id) }
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    private func run(_ id: String, on source: Workspaces) -> (reason: String, isNotFound: Bool)? {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: PaletteSources(workspaces: source), frecencyPersistence: nil)
        palette.bindRegistryActions()
        return registry.capturingTypedRefusal {
            _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: ["workspace": .string(id)]))
        }
    }

    @Test func aSwitchByIDBuildsNoWorkspaceList() {
        let source = Workspaces(Set((0..<60).map { "ws_\($0)" }))
        #expect(run("ws_42", on: source) == nil)
        #expect(source.selected == ["ws_42"])
        #expect(source.listBuilds == 0, "the switch built the whole list \(source.listBuilds) times to check one id")
    }

    @Test func anUnknownIDIsStillRefusedWithNoList() {
        let source = Workspaces(["ws_known"])
        #expect(run("ws_missing", on: source)?.isNotFound == true)
        #expect(source.selected.isEmpty)
        #expect(source.listBuilds == 0)
    }
}
