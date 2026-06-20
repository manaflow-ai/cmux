import Foundation
import Testing
@testable import CmuxWorkspaces

/// A tab fake carrying a live panel registry and a surface->panel map so the
/// resolver's panel-vs-surface branch can be exercised the way the legacy
/// `Workspace.panels` / `panelIdFromSurfaceId` did.
@MainActor
private final class ResolverStubTab: WorkspaceTabRepresenting {
    let id: UUID
    var groupId: UUID?
    var isPinned: Bool = false
    var currentDirectory: String = "/tmp"
    var title: String = ""
    var focusedPanelId: UUID?
    var panelTitles: [UUID: String] = [:]

    /// Live panel ids (legacy `panels.keys`).
    var panelIds: Set<UUID> = []
    /// Surface-id -> owning panel-id (legacy `panelIdFromSurfaceId`).
    var surfaceToPanel: [UUID: UUID] = [:]

    init(id: UUID = UUID()) {
        self.id = id
    }

    func panelExists(_ panelId: UUID) -> Bool { panelIds.contains(panelId) }
    func panelId(forSurfaceId surfaceId: UUID) -> UUID? { surfaceToPanel[surfaceId] }

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {}
    func setCustomColor(_ hex: String?) {}
    func updatePanelTitle(panelId: UUID, title: String) -> Bool { false }
    func applyProcessTitle(_ title: String) {}
}

@MainActor
@Suite struct PanelIdResolverTests {
    @MainActor
    private func makeFixture() -> (
        resolver: PanelIdResolver<ResolverStubTab>,
        model: WorkspacesModel<ResolverStubTab>,
        tab: ResolverStubTab
    ) {
        let model = WorkspacesModel<ResolverStubTab>()
        let tab = ResolverStubTab()
        model.tabs = [tab]
        return (PanelIdResolver(model: model), model, tab)
    }

    @Test("focusedPanelId returns the workspace's focused panel")
    func focusedPanelIdReturnsWorkspaceFocus() {
        let (resolver, _, tab) = makeFixture()
        let panel = UUID()
        tab.focusedPanelId = panel
        #expect(resolver.focusedPanelId(forWorkspaceId: tab.id) == panel)
    }

    @Test("focusedPanelId is nil for an unknown workspace")
    func focusedPanelIdNilForUnknownWorkspace() {
        let (resolver, _, _) = makeFixture()
        #expect(resolver.focusedPanelId(forWorkspaceId: UUID()) == nil)
    }

    @Test("panelId returns the id unchanged when it is already a live panel")
    func panelIdPassesThroughLivePanel() {
        let (resolver, _, tab) = makeFixture()
        let panel = UUID()
        tab.panelIds = [panel]
        #expect(resolver.panelId(forSurfaceOrPanelId: panel, in: tab) == panel)
    }

    @Test("panelId maps a surface id to its owning panel")
    func panelIdMapsSurfaceToPanel() {
        let (resolver, _, tab) = makeFixture()
        let surface = UUID()
        let panel = UUID()
        tab.surfaceToPanel = [surface: panel]
        #expect(resolver.panelId(forSurfaceOrPanelId: surface, in: tab) == panel)
    }

    @Test("panelId is nil when the id is neither a panel nor a mapped surface")
    func panelIdNilForUnknownId() {
        let (resolver, _, tab) = makeFixture()
        #expect(resolver.panelId(forSurfaceOrPanelId: UUID(), in: tab) == nil)
    }

    @Test("a live panel id wins over a surface map collision (legacy order)")
    func panelIdPrefersPanelOverSurfaceMap() {
        let (resolver, _, tab) = makeFixture()
        // The same UUID is both a live panel id and (hypothetically) a surface
        // map key; the legacy code checks panels first, so it returns the id
        // unchanged and never consults the surface map.
        let id = UUID()
        tab.panelIds = [id]
        tab.surfaceToPanel = [id: UUID()]
        #expect(resolver.panelId(forSurfaceOrPanelId: id, in: tab) == id)
    }

    @Test("workspace-id overload resolves through the model then the tab")
    func panelIdByWorkspaceIdResolves() {
        let (resolver, _, tab) = makeFixture()
        let surface = UUID()
        let panel = UUID()
        tab.surfaceToPanel = [surface: panel]
        #expect(resolver.panelId(forSurfaceOrPanelId: surface, inWorkspaceId: tab.id) == panel)
    }

    @Test("workspace-id overload is nil for an unknown workspace")
    func panelIdByWorkspaceIdNilForUnknownWorkspace() {
        let (resolver, _, _) = makeFixture()
        #expect(resolver.panelId(forSurfaceOrPanelId: UUID(), inWorkspaceId: UUID()) == nil)
    }
}
