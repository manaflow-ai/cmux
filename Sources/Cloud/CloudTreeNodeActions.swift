import AppKit
import Foundation

/// Closure bundle handed to Cloud outline rows for the nodes below a machine.
/// Bound once above the outline (never a store below it). Every open verb is
/// `SurfaceCatalog.project` — the same path the socket and `cmux vm open` use —
/// so a row, a drop, and the CLI cannot disagree about what "open" means.
struct CloudTreeNodeActions {
    /// Project a resource into the selected local workspace.
    let project: @MainActor (_ resource: SurfaceResourceID, _ placement: SurfacePlacement, _ reuseExisting: Bool) -> Void
    /// Project a resource while retaining the exact daemon tab placement that
    /// produced the row. This prevents a multi-view terminal from losing its
    /// rename target during materialization.
    let projectRemoteView: @MainActor (_ resource: SurfaceResourceID, _ view: SurfaceRemoteView, _ placement: SurfacePlacement, _ reuseExisting: Bool) -> Void
    /// Project a resource into ONE local workspace, reusing only a pane already in it
    /// (a workspace's own Desktop row: a VNC pane in another workspace neither
    /// satisfies the open nor steals focus).
    let projectInLocalWorkspace: @MainActor (_ resource: SurfaceResourceID, _ workspaceID: UUID) -> Void
    /// Project an exact remote placement into one local workspace, preserving the
    /// daemon tab identity while narrowing reuse to that workspace.
    let projectRemoteViewInLocalWorkspace: @MainActor (_ resource: SurfaceResourceID, _ view: SurfaceRemoteView, _ workspaceID: UUID) -> Void
    /// Start a plain terminal on a machine (in a cmux-tui workspace when given) and show it.
    let newTerminal: @MainActor (_ machine: SurfaceMachineID, _ remoteWorkspaceID: String?) -> Void
    /// Open a whole group (a workspace's terminals and browsers): the first at the
    /// selected workspace, the rest as tabs of that pane. An empty group starts a fresh
    /// terminal in `remoteWorkspaceID` on the machine instead.
    let openGroup: @MainActor (_ machine: SurfaceMachineID, _ group: SurfaceResourceGroup, _ placement: SurfacePlacement, _ remoteWorkspaceID: String?) -> Void
    /// Open a whole group as a NEW local workspace named after it, every resource its own
    /// pane (what clicking a remote workspace row does). An empty group starts a fresh
    /// terminal in `remoteWorkspaceID` on the machine instead.
    let openGroupAsWorkspace: @MainActor (_ machine: SurfaceMachineID, _ group: SurfaceResourceGroup, _ remoteWorkspaceID: String?) -> Void
    /// Create a workspace on the machine (its ⌘N: `workspace create`, then a starter
    /// terminal) and open it as a new local workspace.
    let newWorkspace: @MainActor (_ machine: SurfaceMachineID) -> Void
    /// End a terminal on its machine (the process and its remote tab).
    let closeTerminal: @MainActor (_ resource: SurfaceResourceID) -> Void
    /// Close a workspace on its machine AND kill every terminal in it (austin,
    /// 2026-08-31: a closed workspace never leaves stray terminals behind in the
    /// pool). Confirms first when there is something to kill. The protocol's
    /// keep-terminals close stays CLI-only (`cmux vm workspace close`).
    let closeWorkspace: @MainActor (_ machine: SurfaceMachineID, _ workspace: SurfaceRemoteWorkspace) -> Void
    /// Rename a remote workspace via a text prompt.
    let renameWorkspace: @MainActor (_ machine: SurfaceMachineID, _ workspace: SurfaceRemoteWorkspace) -> Void
    /// Rename a remote terminal placement via a text prompt. A nil view means the
    /// caller selected the machine pool, so the explicit compatibility operation
    /// renames all views.
    let renameTerminal: @MainActor (_ resource: SurfaceResource, _ view: SurfaceRemoteView?) -> Void
    /// Select a local workspace.
    let selectLocalWorkspace: @MainActor (_ workspaceID: UUID) -> Void
    let copyToPasteboard: @MainActor (_ text: String) -> Void
    /// Copy a link that works from any app on this Mac for a machine port: the
    /// loopback forward over the user-space hub, started if needed. The private
    /// address is only reachable with `cmux vpn up`, so it is not what "Copy
    /// Link" hands out.
    let copyPortLink: @MainActor (_ resource: SurfaceResourceID) -> Void
    let refresh: @MainActor () -> Void
    var refreshMachine: @MainActor (_ machine: SurfaceMachineID) -> Void = { _ in }

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
        existingWorkspace: SurfaceRemoteWorkspace? = nil
    ) async throws -> (
        workspace: SurfaceRemoteWorkspace,
        terminal: SurfaceResource,
        opened: (workspaceID: UUID, projections: [SurfaceProjection])?
    ) {
        let workspace: SurfaceRemoteWorkspace
        if let existingWorkspace { workspace = existingWorkspace }
        else { workspace = try await provider.createRemoteWorkspace(name: name) }
        await provider.refresh()
        let existing = catalog.snapshot.resources(on: machine).first { resource in
            resource.id.kind == .terminal && resource.remoteWorkspaces.contains { $0.id == workspace.id }
        }
        let terminal: SurfaceResource
        if let existing {
            terminal = existing
        } else {
            terminal = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: workspace.id)
        }
        // Headless staging (`cmux vm workspace new --no-open`): the machine workspace and
        // its starter terminal are created, but nothing local is created or focused. A
        // later layout apply may target this workspace only when it is still empty.
        guard openLocally else { return (workspace, terminal, nil) }
        let placement = SurfaceResourcePlacement(
            resource: terminal.id,
            remoteView: terminal.remoteViews?.first { $0.workspace.id == workspace.id },
            remoteWorkspaceID: workspace.id
        )
        let group = SurfaceResourceGroup(
            title: workspace.name,
            placements: [placement],
            remoteWorkspaceID: workspace.id
        )
        let opened = try await catalog.projectGroupAsNewLocalWorkspace(
            group,
            title: localWorkspaceTitle(hostName: resolvedMachineName(machine, snapshot: catalog.snapshot), group: group),
            focus: focus,
            host: .app
        )
        catalog.bindCloudWorkspace(
            localWorkspaceID: opened.workspaceID,
            machine: machine,
            remoteWorkspaceID: workspace.id,
            generatedTitle: localWorkspaceTitle(hostName: resolvedMachineName(machine, snapshot: catalog.snapshot), group: group)
        )
        return (workspace, terminal, opened)
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
        await provider.refresh()
        let doomed = catalog.snapshot.resources(on: machine).filter { resource in
            resource.kind == .terminal && resource.remoteWorkspaces.contains { $0.id == workspaceID }
        }
        for terminal in doomed {
            try await provider.closeTerminal(terminal.id)
        }
        try await provider.closeRemoteWorkspace(id: workspaceID)
        return doomed.count
    }


}
