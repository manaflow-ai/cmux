import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Lawrence, 2026-11-26: "on cmd p, the workspace pill takes an additional frame to come in. prob similar with
/// other things like cmd shift A". The content view followed the model through an observation Task that re-armed a
/// run-loop pass later, so the panel's first frame drew the field without its scope chip (the Workspaces pill) and
/// the pill came in one frame after. `present()` now renders the model before ordering the panel front: the chip is
/// in the view tree when the open returns, before the run loop turns once.
@MainActor
@Suite(.paletteRanker, .serialized, .closesItsWindows)
struct PaletteScopeChipFirstFrameTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = [PaletteWorkspace(id: "w1", title: "Backend"), PaletteWorkspace(id: "w2", title: "Docs")]
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    private static func palette() -> PaletteController {
        _ = NSApplication.shared
        let sources = PaletteSources(workspaces: Workspaces())
        let palette = PaletteController(registry: .standard(), sources: sources, frecencyPersistence: nil)
        palette.bindRegistryActions()
        return palette
    }

    /// The chip views the search field holds now, without running the run loop.
    private static func drawnChips(_ palette: PaletteController) -> [NSView] {
        guard let content = palette.visiblePanel?.contentView as? PaletteContentView else { return [] }
        let chips = content.searchBar.subviews.compactMap { $0 as? PaletteScopeChipsView }
        return chips.filter { !$0.isHidden }.flatMap(\.subviews)
    }

    /// Cmd-P (goToWorkspace with no workspace): the Workspaces chip is drawn in the open's own turn.
    @Test func cmdPDrawsTheWorkspacesChipInThePanelsFirstFrame() throws {
        let palette = Self.palette()
        defer { palette.closeForTest() }
        #expect(palette.registry.perform("goToWorkspace"))
        #expect(palette.isVisible)
        try #require(!palette.model.fieldScopeChips.isEmpty, "the Workspaces page has a scope chip to draw")
        #expect(!Self.drawnChips(palette).isEmpty, "the pill was not in the panel when it was ordered front")
    }

    /// Already open on another page: switching to the Workspaces scope draws its chip in the same turn too.
    @Test func switchingPagesWhileOpenDrawsTheChipInTheSameTurn() throws {
        let palette = Self.palette()
        defer { palette.closeForTest() }
        #expect(palette.registry.perform("commandPalette"))
        #expect(palette.isVisible)
        #expect(palette.registry.perform("goToWorkspace"))
        try #require(!palette.model.fieldScopeChips.isEmpty, "the Workspaces page has a scope chip to draw")
        #expect(!Self.drawnChips(palette).isEmpty, "the pill came in a pass after the page switch")
    }
}
