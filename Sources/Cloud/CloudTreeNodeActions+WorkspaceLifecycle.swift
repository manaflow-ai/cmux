import AppKit
import Foundation

extension CloudTreeNodeActions {
    private struct LocalWorkspaceReservation {
        let workspaceID: UUID
        let loadingPanelID: UUID
    }

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
        host: SurfaceCatalog.NewWorkspaceHost? = nil,
        validateOperation: @MainActor () throws -> Void = { try Task.checkCancellation() },
        existingWorkspace: SurfaceRemoteWorkspace? = nil,
        existingTerminal: SurfaceResource? = nil,
        onReceipt: @MainActor (SurfaceRemoteWorkspace, SurfaceResource?) -> Void = { _, _ in },
        onReceiptInvalidated: @MainActor (SurfaceRemoteWorkspace) -> Void = { _ in }
    ) async throws -> (
        workspace: SurfaceRemoteWorkspace,
        terminal: SurfaceResource,
        opened: (workspaceID: UUID, projections: [SurfaceProjection])?
    ) {
        try validateOperation()
        let projectionHost = host ?? .appOptimistic
        let reservation = openLocally
            ? try reserveLocalWorkspace(machine: machine, focus: focus, catalog: catalog, host: host)
            : nil
        // An app-owned presentation workspace is part of the transaction. Do
        // not create remote state that cannot be shown locally if the host is
        // unavailable or its active window changed during admission.
        guard !openLocally || reservation != nil else { throw CancellationError() }
        var committed = false
        var projectionPanelIDs: Set<UUID> = []
        defer {
            if !committed, let reservation {
                rollbackLocalWorkspace(reservation, projectionPanelIDs: projectionPanelIDs)
            }
        }

        let createdRemoteWorkspace = existingWorkspace == nil
        let workspace: SurfaceRemoteWorkspace = if let existingWorkspace { existingWorkspace } else { try await provider.createRemoteWorkspace(name: name) }
        onReceipt(workspace, nil)
        try validateOperation()
        guard !openLocally || isLiveReservation(reservation) else {
            if createdRemoteWorkspace {
                onReceiptInvalidated(workspace)
                await cleanupRemoteWorkspaceCreation(provider: provider, workspace: workspace, terminal: nil)
            }
            throw CancellationError()
        }
        // createRemoteWorkspace installs its committed workspace/terminal receipt
        // into the catalog immediately. Waiting for a full graph refresh here
        // serialized the next terminal mutation behind a redundant snapshot;
        // the provider schedules reconciliation in the background.
        let existing = existingTerminal ?? catalog.snapshot.resources(on: machine).first { resource in
            resource.id.kind == .terminal && resource.remoteWorkspaces.contains { $0.id == workspace.id }
        }
        let terminal: SurfaceResource
        var createdRemoteTerminal = false
        if let existing {
            terminal = existing
        } else {
            terminal = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: workspace.id)
            createdRemoteTerminal = true
        }
        onReceipt(workspace, terminal)
        try validateOperation()
        guard openLocally else {
            committed = true
            return (workspace, terminal, nil)
        }
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
        guard let reservation else { throw CancellationError() }
        guard isLiveReservation(reservation) else {
            if createdRemoteTerminal || createdRemoteWorkspace {
                onReceiptInvalidated(workspace)
                await cleanupRemoteWorkspaceCreation(
                    provider: provider,
                    workspace: workspace,
                    terminal: createdRemoteTerminal ? terminal : nil
                )
            }
            throw CancellationError()
        }
        let projections = try await catalog.projectGroup(
            group,
            into: .workspace(id: reservation.workspaceID, placement: .split),
            focus: focus,
            paneLookup: projectionHost.paneLookup,
            optimistic: projectionHost.optimistic
        )
        projectionPanelIDs = Set(projections.map(\.panelID))
        try validateOperation()
        if let loadingWorkspace = Workspace.liveWorkspace(id: reservation.workspaceID),
           loadingWorkspace.panels[reservation.loadingPanelID] != nil {
            projectionHost.closeStarter(reservation.loadingPanelID, reservation.workspaceID)
        } else {
            if createdRemoteTerminal || createdRemoteWorkspace {
                onReceiptInvalidated(workspace)
                await cleanupRemoteWorkspaceCreation(
                    provider: provider,
                    workspace: workspace,
                    terminal: createdRemoteTerminal ? terminal : nil
                )
            }
            throw CancellationError()
        }
        let generatedTitle = localWorkspaceTitle(
            hostName: resolvedMachineName(machine, snapshot: catalog.snapshot),
            group: group
        )
        if let loadingWorkspace = Workspace.liveWorkspace(id: reservation.workspaceID),
           loadingWorkspace.effectiveCustomTitleSource != .user,
           let manager = loadingWorkspace.owningTabManager
               ?? AppDelegate.shared?.tabManagerFor(tabId: reservation.workspaceID) {
            _ = manager.setCustomTitle(
                tabId: reservation.workspaceID,
                title: generatedTitle,
                source: .remote,
                propagateToRemoteTmux: false,
                propagateToCloud: false,
                catalog: catalog
            )
        }
        catalog.bindCloudWorkspace(
            localWorkspaceID: reservation.workspaceID,
            machine: machine,
            remoteWorkspaceID: workspace.id,
            generatedTitle: generatedTitle
        )
        if focus, let first = projections.first { SurfacePaneFactory.focus(panelID: first.panelID, in: first.workspaceID) }
        committed = true
        return (workspace, terminal, (reservation.workspaceID, projections))
    }

    /// Reserves the local loading workspace before the first remote workspace request.
    /// The caller owns the reservation until the terminal projection commits.
    @MainActor
    private static func reserveLocalWorkspace(
        machine: SurfaceMachineID,
        focus: Bool,
        catalog: SurfaceCatalog,
        host: SurfaceCatalog.NewWorkspaceHost?
    ) throws -> LocalWorkspaceReservation? {
        let title = String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM")
        let workspace: Workspace
        let starterPanelID: UUID?
        if let host {
            // A supplied host already captured the originating window. Never
            // redirect its reservation to a window selected after admission.
            let created = try host.create(title)
            guard let createdWorkspace = Workspace.liveWorkspace(id: created.workspaceID) else { return nil }
            workspace = createdWorkspace
            starterPanelID = created.starterPanelID
        } else {
            guard let appDelegate = AppDelegate.shared else { return nil }
            let preferredWindow = NSApp.keyWindow ?? NSApp.mainWindow
            let context = appDelegate.contextForMainWindow(preferredWindow)
                ?? appDelegate.preferredMainWindowContextForWorkspaceCreation(
                    debugSource: "cloudWorkspace.optimisticReservation"
                )
            guard let tabManager = context?.tabManager
                ?? appDelegate.activeTabManagerForCommands(preferredWindow: preferredWindow),
                  let createdWorkspace = tabManager.addWorkspaceIfActive(
                    title: title,
                    titleSource: .auto,
                    initialSurface: .cloudVMLoading,
                    inheritWorkingDirectory: false,
                    select: focus,
                    autoWelcomeIfNeeded: false
                  ) else { return nil }
            workspace = createdWorkspace
            starterPanelID = nil
        }
        let loadingPanel = starterPanelID.flatMap { workspace.panels[$0] as? CloudVMLoadingPanel }
            ?? workspace.panels.values.compactMap({ $0 as? CloudVMLoadingPanel }).first
        guard let loadingPanel else {
            return nil
        }
        let machineName = resolvedMachineName(machine, snapshot: catalog.snapshot)
        loadingPanel.configureLoadingHeadline(String(format: String(
            localized: "cloudTree.operation.newWorkspace",
            defaultValue: "Creating a workspace on %@\u{2026}"
        ), machineName))
        return LocalWorkspaceReservation(workspaceID: workspace.id, loadingPanelID: loadingPanel.id)
    }

    @MainActor
    private static func rollbackLocalWorkspace(
        _ reservation: LocalWorkspaceReservation,
        projectionPanelIDs: Set<UUID>
    ) {
        guard let workspace = Workspace.liveWorkspace(id: reservation.workspaceID),
              let manager = workspace.owningTabManager
                  ?? AppDelegate.shared?.tabManagerFor(tabId: reservation.workspaceID),
              workspace.effectiveCustomTitleSource != .user else { return }
        // Projection may have succeeded before a scope/cancellation check failed.
        // Roll back only panes this transaction owns; user edits take ownership.
        let ownedPanelIDs = projectionPanelIDs.union([reservation.loadingPanelID])
        guard Set(workspace.panels.keys).isSubset(of: ownedPanelIDs) else { return }
        manager.closeWorkspace(workspace, recordHistory: false)
    }

    @MainActor
    private static func isLiveReservation(_ reservation: LocalWorkspaceReservation?) -> Bool {
        guard let reservation,
              let workspace = Workspace.liveWorkspace(id: reservation.workspaceID) else { return false }
        return workspace.panels[reservation.loadingPanelID] is CloudVMLoadingPanel
    }

    private static func cleanupRemoteWorkspaceCreation(
        provider: any SurfaceProvider,
        workspace: SurfaceRemoteWorkspace,
        terminal: SurfaceResource?
    ) async {
        if let terminal { try? await provider.closeTerminal(terminal.id) }
        try? await provider.closeRemoteWorkspace(id: workspace.id)
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
