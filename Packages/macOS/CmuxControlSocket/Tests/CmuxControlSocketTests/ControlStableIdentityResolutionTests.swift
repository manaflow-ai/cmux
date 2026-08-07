import Foundation
import Testing
@testable import CmuxControlSocket

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9745.
///
/// The UI's `Copy cmux link` emits restart-stable ids (`Workspace.stableId` /
/// `Panel.stableSurfaceId`), not the runtime ids the socket routes with. Every
/// identifier param must accept either, or a pasted link fails with
/// `not_found` through the CLI while navigating correctly when opened.
@MainActor
@Suite("Control socket stable identity resolution")
struct ControlStableIdentityResolutionTests {
    private let stableWorkspace = UUID()
    private let runtimeWorkspace = UUID()
    private let stableSurface = UUID()
    private let runtimeSurface = UUID()

    private func coordinator() -> ControlCommandCoordinator {
        let c = ControlCommandCoordinator()
        c.setStableAliases(
            kind: .workspace,
            [stableWorkspace: runtimeWorkspace],
            runtimeIds: [runtimeWorkspace]
        )
        c.setStableAliases(
            kind: .surface,
            [stableSurface: runtimeSurface],
            runtimeIds: [runtimeSurface]
        )
        return c
    }

    @Test func routesAStableWorkspaceIdToItsRuntimeId() {
        let c = coordinator()
        #expect(c.uuid(["workspace_id": .string(stableWorkspace.uuidString)], "workspace_id")
            == runtimeWorkspace)
    }

    @Test func routesAStableSurfaceIdToItsRuntimeId() {
        let c = coordinator()
        #expect(c.uuid(["surface_id": .string(stableSurface.uuidString)], "surface_id")
            == runtimeSurface)
    }

    /// `terminal_id` and `tab_id` are legacy spellings of `surface_id` and must
    /// not silently keep the old runtime-only behavior.
    @Test func routesStableIdsThroughTheLegacySurfaceParamSpellings() {
        let c = coordinator()
        #expect(c.uuid(["terminal_id": .string(stableSurface.uuidString)], "terminal_id")
            == runtimeSurface)
        #expect(c.uuid(["tab_id": .string(stableSurface.uuidString)], "tab_id")
            == runtimeSurface)
    }

    /// The whole routing selector set resolves at once, which is what makes
    /// every command inherit the behavior from one parse site.
    @Test func routingSelectorsResolveStableIdsForWorkspaceAndSurface() {
        let c = coordinator()
        let selectors = c.routingSelectors([
            "workspace_id": .string(stableWorkspace.uuidString),
            "surface_id": .string(stableSurface.uuidString),
        ])
        #expect(selectors.workspaceID == runtimeWorkspace)
        #expect(selectors.surfaceID == runtimeSurface)
    }

    @Test func leavesRuntimeIdsUntouched() {
        let c = coordinator()
        #expect(c.uuid(["surface_id": .string(runtimeSurface.uuidString)], "surface_id")
            == runtimeSurface)
        #expect(c.uuid(["workspace_id": .string(runtimeWorkspace.uuidString)], "workspace_id")
            == runtimeWorkspace)
    }

    @Test func leavesUnknownIdsUntouchedSoResolversStillReportNotFound() {
        let c = coordinator()
        let unknown = UUID()
        #expect(c.uuid(["surface_id": .string(unknown.uuidString)], "surface_id") == unknown)
    }

    /// Aliases are namespaced per kind: a surface's stable id must not rewrite a
    /// workspace param, or a link would route to an unrelated object.
    @Test func doesNotApplyAnAliasAcrossHandleKinds() {
        let c = coordinator()
        #expect(c.uuid(["workspace_id": .string(stableSurface.uuidString)], "workspace_id")
            == stableSurface)
    }

    /// Params that do not name a topology object keep raw UUID passthrough.
    @Test func leavesNonTopologyParamsUnmapped() {
        let c = coordinator()
        #expect(ControlCommandCoordinator.handleKind(forParamKey: "checkpoint_id") == nil)
        #expect(c.uuid(["checkpoint_id": .string(stableSurface.uuidString)], "checkpoint_id")
            == stableSurface)
    }

    @Test func refsStillResolveThroughTheHandleRegistry() {
        let c = coordinator()
        let ref = c.ensureRef(kind: .surface, uuid: runtimeSurface)
        #expect(c.uuid(["surface_id": .string(ref)], "surface_id") == runtimeSurface)
    }
}

/// The table's own invariants, independent of param parsing.
@Suite("ControlStableIdentityTable")
struct ControlStableIdentityTableTests {
    /// A live runtime id must never be reinterpreted as another object's stable
    /// id, matching `CmuxNavigationTargetResolver`'s runtime-first precedence.
    @Test func runtimeIdentityWinsOverACollidingAlias() {
        let table = ControlStableIdentityTable()
        let contested = UUID()
        let other = UUID()
        table.replace(
            kind: .surface,
            aliases: [contested: other],
            excludingRuntimeIds: [contested]
        )
        #expect(table.runtimeUUID(for: contested, kind: .surface) == contested)
    }

    @Test func selfAliasesAreDropped() {
        let table = ControlStableIdentityTable()
        let id = UUID()
        table.replace(kind: .workspace, aliases: [id: id], excludingRuntimeIds: [])
        #expect(table.runtimeUUID(for: id, kind: .workspace) == id)
    }

    /// Replacement is wholesale: a closed workspace's stable id must stop
    /// resolving rather than route a later command to a dead runtime id.
    @Test func replacingForgetsAliasesForClosedObjects() {
        let table = ControlStableIdentityTable()
        let stale = UUID()
        let staleRuntime = UUID()
        let live = UUID()
        let liveRuntime = UUID()
        table.replace(
            kind: .workspace,
            aliases: [stale: staleRuntime, live: liveRuntime],
            excludingRuntimeIds: [staleRuntime, liveRuntime]
        )
        #expect(table.runtimeUUID(for: stale, kind: .workspace) == staleRuntime)

        table.replace(kind: .workspace, aliases: [live: liveRuntime], excludingRuntimeIds: [liveRuntime])
        #expect(table.runtimeUUID(for: stale, kind: .workspace) == stale)
        #expect(table.runtimeUUID(for: live, kind: .workspace) == liveRuntime)
    }

    @Test func kindsAreIndependent() {
        let table = ControlStableIdentityTable()
        let stable = UUID()
        let runtime = UUID()
        table.replace(kind: .surface, aliases: [stable: runtime], excludingRuntimeIds: [runtime])
        #expect(table.runtimeUUID(for: stable, kind: .surface) == runtime)
        #expect(table.runtimeUUID(for: stable, kind: .workspace) == stable)
        #expect(table.runtimeUUID(for: stable, kind: .pane) == stable)
    }
}
