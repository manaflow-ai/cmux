import AppKit
import Foundation

extension CloudTreeNodeActions {
    /// The local workspace's title: the remote workspace's own name — what a
    /// person actually named it, or typed into its terminal — never the
    /// machine's raw provider id. `hostName` (the machine's friendly label)
    /// only shows up when the workspace itself has no name to show.
    static func localWorkspaceTitle(hostName: String, group: SurfaceResourceGroup) -> String {
        let name = group.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? hostName : name
    }
    /// The machine's friendly label — `SurfaceMachineInfo.name` (the same
    /// preferred name its own sidebar row shows), never the raw provider VM
    /// id. Shared by every caller that needs a machine's name in
    /// user-visible text (progress labels, a compound workspace title).
    static func resolvedMachineName(_ machine: SurfaceMachineID, snapshot: SurfaceCatalogSnapshot) -> String {
        if machine.isLocal { return String(localized: "cloudTree.machine.local", defaultValue: "This Mac") }
        let name = snapshot.machines.first(where: { $0.id == machine })?.name
        return name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? name! : machine.rawValue
    }

    /// The machine's ⌘N, shared by the sidebar's ＋ and the socket's `vm.workspace_new`:
    /// create the cmux-tui workspace, give it a starter terminal, and open it as a new
    /// local workspace. The daemon may attach its own starter to a created workspace
    /// (older cmux-tui builds do), so an existing terminal is reused before a second one
    /// is created — ⌘N must yield exactly one pane.
    @MainActor
    static func createWorkspaceAndOpenLocally(
        machine: SurfaceMachineID,
        provider: any SurfaceProvider,
        catalog: SurfaceCatalog,
        name: String?,
        focus: Bool,
        openLocally: Bool = true,
        existingWorkspace: SurfaceRemoteWorkspace? = nil,
        existingTerminal: SurfaceResource? = nil,
        host suppliedHost: CloudWorkspaceCreationHost? = nil,
        validateOperation: @escaping @MainActor () throws -> Void = { try Task.checkCancellation() },
        reuseFailedCreation: Bool = false
    ) async throws -> (
        workspace: SurfaceRemoteWorkspace,
        terminal: SurfaceResource,
        opened: (workspaceID: UUID, projections: [SurfaceProjection])?
    ) {
        let host: CloudWorkspaceCreationHost?
        if openLocally, let suppliedHost {
            host = suppliedHost
        } else if openLocally {
            guard let manager = AppDelegate.shared?.preferredMainWindowContextForWorkspaceCreation(
                debugSource: "cloud.workspace.create"
            )?.tabManager else { throw CancellationError() }
            host = CloudWorkspaceCreationHost(manager: manager)
        } else {
            host = nil
        }
        return try await catalog.cloudWorkspaceCreationCoordinator.create(
            provider: provider, name: name, focus: focus, host: host, reuseFailedCreation: reuseFailedCreation,
            existingWorkspace: existingWorkspace, existingTerminal: existingTerminal,
            validateOperation: validateOperation
        )
    }

    /// The full close, shared by the sidebar's "Close Workspace…" (menu and hover ×) and
    /// the socket's `vm.workspace_delete`: kill every terminal viewed in the workspace,
    /// then close the workspace. Re-syncs and re-enumerates AT operation time — the
    /// sidebar's pre-confirm list only words its dialog; a terminal created while the
    /// dialog was up must die with the workspace too, never linger in the pool. Returns
    /// how many terminals were closed. (Plain `closeRemoteWorkspace` is the protocol's
    /// keep-terminals close, reachable only from the CLI / `vm.workspace_close`.)
    @MainActor
    @discardableResult
    static func deleteWorkspaceAndTerminals(
        machine: SurfaceMachineID,
        provider: any SurfaceProvider,
        catalog: SurfaceCatalog,
        workspaceID: String
    ) async throws -> Int {
        let deletion = catalog.deleteCloudWorkspace(machine: machine, workspaceID: workspaceID, provider: provider)
        return try await withTaskCancellationHandler {
            try await deletion.value
        } onCancel: {
            deletion.cancel()
        }
    }
}
