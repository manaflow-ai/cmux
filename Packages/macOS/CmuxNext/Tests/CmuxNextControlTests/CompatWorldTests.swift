import CmuxNextDaemon
@testable import CmuxNextControl
import Foundation
import Testing

/// Two workspaces; the first has two panes (a split) with three tabs.
func sampleTree() -> DaemonTree {
    let term = TabSnapshot(surface: 11, tabResourceID: "tab_00000000000000000000000000000011",
                           terminalID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", kind: .pty, title: "zsh", cwd: "/tmp")
    let second = TabSnapshot(surface: 12, tabResourceID: "tab_00000000000000000000000000000012", kind: .pty, title: "vim")
    var browser = TabSnapshot(surface: 13, tabResourceID: "tab_00000000000000000000000000000013", kind: .browser, title: "Example",
                              url: "https://example.com", browserRenderer: "frontend", browserEngine: "webkit")
    browser.pinned = false
    let left = PaneSnapshot(id: 2, resourceID: "pane_00000000000000000000000000000002", activeTab: 1, tabs: [term, second])
    let right = PaneSnapshot(id: 3, resourceID: "pane_00000000000000000000000000000003", tabs: [browser])
    let screen = ScreenSnapshot(id: 1, active: true, activePane: 2,
                                layout: .split(id: 5, direction: .right, ratio: 0.5, a: .leaf(2), b: .leaf(3)), panes: [right, left])
    let other = ScreenSnapshot(id: 9, active: true, activePane: 8, layout: .leaf(8), panes: [
        PaneSnapshot(id: 8, resourceID: "pane_00000000000000000000000000000008",
                     tabs: [TabSnapshot(surface: 21, tabResourceID: "tab_00000000000000000000000000000021", title: "logs")]),
    ])
    return DaemonTree(workspaces: [
        WorkspaceSnapshot(id: 1, key: "11111111-1111-4111-8111-111111111111", name: "alpha", screens: [screen]),
        WorkspaceSnapshot(id: 7, key: "22222222-2222-4222-8222-222222222222", name: "beta", screens: [other], title: "Beta!"),
    ])
}

@Suite struct CompatWorldTests {
    @Test func uuidsAreStableAndOldAppShaped() {
        #expect(CompatUUID.from(resourceID: "pane_0ae95a5a741e319f7bb0f753bc72a2ad") == "0AE95A5A-741E-319F-7BB0-F753BC72A2AD")
        #expect(CompatUUID.from(resourceID: "11111111-1111-4111-8111-111111111111") == "11111111-1111-4111-8111-111111111111")
        let hashed = CompatUUID.from(resourceID: "pane:12")
        #expect(UUID(uuidString: hashed) != nil && hashed == CompatUUID.from(resourceID: "pane:12"))
    }

    @Test func refsAreMonotonicPerKindAndNeverReused() {
        let refs = CompatRefRegistry()
        #expect(refs.ref(.workspace, "A") == "workspace:1")
        #expect(refs.ref(.workspace, "B") == "workspace:2")
        #expect(refs.ref(.workspace, "A") == "workspace:1")
        #expect(refs.ref(.pane, "A") == "pane:1")
        #expect(refs.uuid(.workspace, number: 2) == "B")
        #expect(CompatRefRegistry.parse("surface:12")?.number == 12)
        #expect(CompatRefRegistry.parse("tab:3") == nil)
    }

    @Test func buildOrdersByLayoutAndUsesFrontendFocus() throws {
        let refs = CompatRefRegistry()
        let frontend = CompatFrontendSnapshot(windows: [
            .init(id: "win-1", workspaceID: "11111111-1111-4111-8111-111111111111",
                  focusedPaneID: "pane_00000000000000000000000000000003", isKey: true),
        ], activeWindowID: "win-1")
        let world = CompatWorld(tree: sampleTree(), frontend: frontend, refs: refs)
        #expect(world.workspaces.map(\.title) == ["alpha", "Beta!"])
        let alpha = world.workspaces[0]
        let panes = world.orderedPanes(in: alpha)
        // Layout order (left leaf first), not the snapshot's pane array order.
        #expect(panes.map(\.handle) == [2, 3])
        #expect(panes[1].focused && !panes[0].focused)
        // No frontend selection for pane 2: the daemon's active_tab wins.
        #expect(world.surfaces[panes[0].selectedSurfaceUUID ?? ""]?.title == "vim")
        let focus = world.focus(in: alpha)
        #expect(focus.surface?.typeName == "browser" && focus.surface?.focused == true)
        #expect(world.currentWorkspace(window: world.activeWindow)?.uuid == alpha.uuid)
        #expect(alpha.windowUUIDs == [world.windows[0].uuid])
    }

    @Test func resolvesUUIDsRefsIndexesAndTerminalAliases() throws {
        let refs = CompatRefRegistry()
        let world = CompatWorld(tree: sampleTree(), frontend: CompatFrontendSnapshot(), refs: refs)
        let beta = try world.resolveWorkspace("22222222-2222-4222-8222-222222222222", refs: refs)
        #expect(try world.resolveWorkspace(beta.ref, refs: refs).uuid == beta.uuid)
        #expect(try world.resolveWorkspace("1", refs: refs).uuid == beta.uuid)
        let alpha = world.workspaces[0]
        let vim = try world.resolveSurface("1", in: alpha, refs: refs)
        #expect(vim.title == "vim")
        let zsh = try world.resolveSurface("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", in: nil, refs: refs)
        #expect(zsh.title == "zsh")
        #expect(try world.resolveSurface("tab_00000000000000000000000000000013", in: nil, refs: refs).typeName == "browser")
        #expect(throws: ControlError.self) { try world.resolvePane("pane:999", in: alpha, refs: refs) }
        #expect(throws: ControlError.self) { try world.resolveWorkspace("pane:1", refs: refs) }
    }

    @Test func targetFallsBackFromSurfaceToItsWorkspace() throws {
        let refs = CompatRefRegistry()
        let world = CompatWorld(tree: sampleTree(), frontend: CompatFrontendSnapshot(), refs: refs)
        let logs = world.surfaces.values.first { $0.title == "logs" }!
        let target = CompatTarget(world: world, refs: refs, params: ["surface_id": .string(logs.uuid)])
        #expect(try target.workspace().title == "Beta!")
        #expect(try target.pane().handle == 8)
    }
}
