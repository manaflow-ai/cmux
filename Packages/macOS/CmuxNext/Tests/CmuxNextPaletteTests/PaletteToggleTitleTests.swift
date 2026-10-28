import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Lawrence 2026-10-27: the palette's "Pin/Unpin Workspace" did not say whether the workspace was
/// pinned. A toggle's row names the change it makes for the focused object (Pin Workspace or
/// Unpin Workspace) and a search for either word still finds it.
@MainActor
struct PaletteToggleTitleTests {
    final class State { var pinned = false }

    static func items(_ registry: ActionRegistry) -> [PaletteItem] {
        RegistryPaletteProvider(registry: registry).makeItems()
    }

    @Test func aToggleRowNamesTheChangeItMakes() throws {
        let registry = ActionRegistry.standard()
        let state = State()
        registry.bind("palette.toggleWorkspacePin") { state.pinned.toggle() }
        ActionTargetTitles.setState("palette.toggleWorkspacePin", in: registry) { _ in state.pinned }

        let unpinned = try #require(Self.items(registry).first { $0.actionID == "palette.toggleWorkspacePin" })
        #expect(unpinned.title == "Pin Workspace")
        state.pinned = true
        let pinned = try #require(Self.items(registry).first { $0.actionID == "palette.toggleWorkspacePin" })
        #expect(pinned.title == "Unpin Workspace")
        // A title that says the change needs no check mark as well.
        #expect(pinned.symbol != "checkmark.circle.fill")
        // Typing either verb finds the row.
        let words = (pinned.keywords + [pinned.title]).map { $0.lowercased() }
        #expect(words.contains { $0.contains("unpin workspace") })
        #expect(words.contains { $0.hasPrefix("pin workspace") })
    }
}
