import CMUXMobileCore
import Testing
@testable import CmuxMobileShellModel

/// Covers the surface shown when the picker has no explicit Mac-surface
/// selection. A workspace whose panes are all non-terminal (for example a
/// lone todo panel) has no terminal to stream, so without a fallback the
/// detail view renders an empty terminal background.
struct MobileWorkspacePreviewDefaultSurfaceTests {
    private func surface(
        id: MobileSurfacePreview.ID,
        kind: MobileSurfacePreview.Kind,
        todo: MobileTodoSnapshot? = nil
    ) -> MobileSurfacePreview {
        MobileSurfacePreview(id: id, kind: kind, title: "Surface", todo: todo)
    }

    private func workspace(
        terminals: [MobileTerminalPreview],
        surfaces: [MobileSurfacePreview]
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: "workspace-1",
            name: "TODO - iOS",
            terminals: terminals,
            surfaces: surfaces
        )
    }

    private var todoSurface: MobileSurfacePreview {
        surface(
            id: "surface-todo",
            kind: .todo,
            todo: MobileTodoSnapshot(status: .todo, statusHidden: false, items: [])
        )
    }

    @Test func noTerminalsFallsBackToFirstNonTerminalSurface() {
        let workspace = workspace(terminals: [], surfaces: [todoSurface])
        #expect(workspace.selectedMacSurface(id: nil) == todoSurface)
    }

    @Test func fallbackSkipsTerminalKindedSurfaces() {
        let terminalSurface = surface(id: "surface-term", kind: .terminal)
        let workspace = workspace(terminals: [], surfaces: [terminalSurface, todoSurface])
        #expect(workspace.selectedMacSurface(id: nil) == todoSurface)
    }

    @Test func fallbackPicksFirstNonTerminalSurfaceInSpatialOrder() {
        let browserSurface = surface(id: "surface-browser", kind: .browser)
        let workspace = workspace(terminals: [], surfaces: [browserSurface, todoSurface])
        #expect(workspace.selectedMacSurface(id: nil) == browserSurface)
    }

    @Test func staleSelectionFallsBackWhenTerminalless() {
        let workspace = workspace(terminals: [], surfaces: [todoSurface])
        #expect(workspace.selectedMacSurface(id: "surface-closed") == todoSurface)
    }

    @Test func staleSelectionKeepsTerminalWhenTerminalsExist() {
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "zsh")
        let workspace = workspace(terminals: [terminal], surfaces: [todoSurface])
        #expect(workspace.selectedMacSurface(id: "surface-closed") == nil)
    }

    @Test func explicitSelectionStillWins() {
        let browserSurface = surface(id: "surface-browser", kind: .browser)
        let workspace = workspace(terminals: [], surfaces: [todoSurface, browserSurface])
        #expect(workspace.selectedMacSurface(id: browserSurface.id) == browserSurface)
    }

    @Test func terminalsPresentKeepTerminalAsDefault() {
        let terminal = MobileTerminalPreview(id: "terminal-1", name: "zsh")
        let workspace = workspace(terminals: [terminal], surfaces: [todoSurface])
        #expect(workspace.selectedMacSurface(id: nil) == nil)
    }

    @Test func noNonTerminalSurfacesReturnsNil() {
        let terminalSurface = surface(id: "surface-term", kind: .terminal)
        let workspace = workspace(terminals: [], surfaces: [terminalSurface])
        #expect(workspace.selectedMacSurface(id: nil) == nil)
    }
}
