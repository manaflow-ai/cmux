import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// `PaletteOnDemand`: sources written before the build reach the palette, the palette is
/// built once with its hooks in order, and a palette action run before the build builds it in that run.
@MainActor
@Suite(.paletteRanker)
struct PaletteOnDemandBuildTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = [PaletteWorkspace(id: "ws_known", title: "Known")]
        var selected: [String] = []
        func selectWorkspace(id: String) { selected.append(id) }
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    @MainActor private final class Builds {
        var count = 0
        var hooks: [String] = []
    }

    private static func onDemand(_ registry: ActionRegistry, _ builds: Builds, workspaces: Workspaces = Workspaces()) -> PaletteOnDemand {
        PaletteOnDemand(registry: registry, sources: { PaletteSources(workspaces: workspaces) }) { sources in
            builds.count += 1
            return PaletteController(registry: registry, sources: sources, frecencyPersistence: nil)
        }
    }

    @Test func sourcesWrittenBeforeTheBuildReachThePaletteAndWritesAfterItGoToIt() {
        _ = NSApplication.shared
        let builds = Builds()
        let palettes = Self.onDemand(ActionRegistry.standard(), builds)
        palettes.sources.actionPages["tab.search"] = { nil }
        #expect(builds.count == 0 && palettes.built == nil, "a write builds nothing")
        #expect(palettes.sources.workspaces != nil, "the first sources are made at the first read")
        let palette = palettes.controller
        #expect(palette.sources.actionPages["tab.search"] != nil)
        palettes.sources.actionPages["file.open"] = { nil }
        #expect(palette.sources.actionPages["file.open"] != nil, "after the build, writes go to the palette")
        #expect(palettes.controller === palette && builds.count == 1, "built once")
    }

    @Test func hooksRunOnceAtTheBuildInOrderAndAtOnceAfterIt() {
        _ = NSApplication.shared
        let builds = Builds()
        let palettes = Self.onDemand(ActionRegistry.standard(), builds)
        palettes.whenBuilt { [builds] _ in builds.hooks.append("focus") }
        palettes.whenBuilt { [builds] palette in
            builds.hooks.append("chromium")
            #expect(palettes.built === palette, "a hook sees the palette already built")
        }
        #expect(builds.hooks.isEmpty)
        _ = palettes.controller
        _ = palettes.controller
        #expect(builds.hooks == ["focus", "chromium"])
        palettes.whenBuilt { [builds] _ in builds.hooks.append("late") }
        #expect(builds.hooks == ["focus", "chromium", "late"], "a hook after the build runs at once")
    }

    @Test func aPaletteActionBeforeTheBuildBuildsItInThatRun() {
        _ = NSApplication.shared
        let builds = Builds(), workspaces = Workspaces()
        let registry = ActionRegistry.standard()
        let palettes = Self.onDemand(registry, builds, workspaces: workspaces)
        palettes.bindRegistryActions()
        #expect(builds.count == 0, "binding builds nothing")
        _ = registry.perform("goToWorkspace", invocation: ActionInvocation(arguments: ["workspace": .string("ws_known")]))
        #expect(builds.count == 1, "the run built the palette")
        #expect(workspaces.selected == ["ws_known"], "and ran on it")
        #expect(registry.perform("commandPalette"))
        #expect(builds.count == 1 && palettes.built?.isVisible == true, "the key opens the same palette")
        palettes.built?.hide()
    }
}
