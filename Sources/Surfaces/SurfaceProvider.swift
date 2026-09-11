import Foundation

/// A provider owns the resources of one machine and knows how to put one on screen.
/// Providers push resource changes into the catalog (`catalog.replaceResources`) and the
/// catalog asks them to materialize a projection. They never track projections themselves.
@MainActor
protocol SurfaceProvider: AnyObject {
    var machine: SurfaceMachineID { get }
    var info: SurfaceMachineInfo { get }
    /// Whether this provider can materialize a machine port as a browser preview.
    /// Providers with a direct private-network URL may report true even when no
    /// control-plane `openPort` call is needed.
    var supportsPortPreviews: Bool { get }
    /// Re-sync from the source of truth (machine list, link snapshot, local panels).
    func refresh() async
    /// Re-sync this provider, optionally bypassing provider-side caches. The
    /// default preserves the legacy provider contract; cloud providers use the
    /// force bit for an explicit `--refresh` request.
    func refresh(force: Bool) async
    /// Create the pane that shows `resource` at `destination` and return the panel it created
    /// (or reused). The catalog records the projection.
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection
    /// Same operation with an exact remote placement. A terminal can appear in several
    /// daemon tabs, so callers that came from a workspace pointer pass that tab here.
    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection
    /// Create a new terminal on this machine (remote providers create it in the cmux-tui
    /// session; the local provider spawns a shell) and return its resource.
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource
    /// Called when a pane projecting one of this provider's resources goes away. Remote
    /// providers do nothing (the resource lives on); the local provider drops the resource.
    func projectionDidEnd(_ projection: SurfaceProjection)
    /// End a terminal on this machine (the process and its remote tab). Providers that
    /// cannot (the local machine) throw `SurfaceCatalogError.unsupported`.
    func closeTerminal(_ id: SurfaceResourceID) async throws
    /// Create a new, empty workspace on this machine, directly (not as a side effect of
    /// creating a terminal). Providers without remote workspaces refuse.
    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace
    /// Close a workspace view on this machine. Its terminals detach into the pool
    /// (`spec/cli.md`: only `terminal close` kills); callers wanting a full delete
    /// close each terminal first.
    func closeRemoteWorkspace(id: String) async throws
    /// Rename a remote workspace.
    func renameRemoteWorkspace(id: String, name: String) async throws
    /// Rename one remote tab placement. Tab names are placement-local even when several
    /// tabs point at the same terminal.
    func renameRemoteTab(id: String, name: String) async throws
    /// Compatibility operation that explicitly renames every tab placement of a terminal.
    /// New UI paths must use `renameRemoteTab` when they have a placement reference.
    func renameTerminal(_ id: SurfaceResourceID, name: String) async throws
    /// Close a projection's pane: a materialization that lost a race with an existing
    /// projection, or a URL-backed pane whose machine was unregistered. The default
    /// implementation handles providers that use the shared pane factory; providers may
    /// also clear provider-specific bookkeeping. Return true when the provider preserved
    /// the projection, as the local provider does for a moved pane.
    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool
}

extension SurfaceProvider {
    /// Legacy providers predate the capability bit and are assumed to support
    /// previews until their concrete implementation says otherwise.
    var supportsPortPreviews: Bool { true }

    func refresh(force: Bool) async {
        await refresh()
    }

    func materialize(_ resource: SurfaceResource, remoteView: SurfaceRemoteView?, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        try await materialize(resource, at: destination, focus: focus)
    }

    func closeTerminal(_ id: SurfaceResourceID) async throws {
        throw SurfaceCatalogError.unsupported("closing terminals on \(machine)")
    }
    func createRemoteWorkspace(name: String?) async throws -> SurfaceRemoteWorkspace {
        throw SurfaceCatalogError.unsupported("workspaces on \(machine)")
    }
    func closeRemoteWorkspace(id: String) async throws {
        throw SurfaceCatalogError.unsupported("closing workspaces on \(machine)")
    }
    func renameRemoteWorkspace(id: String, name: String) async throws {
        throw SurfaceCatalogError.unsupported("workspaces on \(machine)")
    }
    func renameRemoteTab(id: String, name: String) async throws {
        throw SurfaceCatalogError.unsupported("renaming tabs on \(machine)")
    }
    func renameTerminal(_ id: SurfaceResourceID, name: String) async throws {
        throw SurfaceCatalogError.unsupported("renaming terminals on \(machine)")
    }
    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        return false
    }
}
