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
        existingWorkspace: SurfaceRemoteWorkspace? = nil,
        existingTerminal: SurfaceResource? = nil,
        onReceipt: @MainActor (SurfaceRemoteWorkspace, SurfaceResource?) -> Void = { _, _ in }
    ) async throws -> (
        workspace: SurfaceRemoteWorkspace,
        terminal: SurfaceResource,
        opened: (workspaceID: UUID, projections: [SurfaceProjection])?
    ) {
        let reservation = openLocally
            ? reserveLocalWorkspace(machine: machine, focus: focus, catalog: catalog)
            : nil
        // An app-owned presentation workspace is part of the transaction. Do
        // not create remote state that cannot be shown locally if the host is
        // unavailable or its active window changed during admission.
        guard !openLocally || reservation != nil else { throw CancellationError() }
        var committed = false
        defer {
            if !committed, let reservation {
                rollbackLocalWorkspace(reservation)
            }
        }

        let createdRemoteWorkspace = existingWorkspace == nil
        let workspace: SurfaceRemoteWorkspace = if let existingWorkspace { existingWorkspace } else { try await provider.createRemoteWorkspace(name: name) }
        onReceipt(workspace, nil)
        guard !openLocally || isLiveReservation(reservation) else {
            if createdRemoteWorkspace { await cleanupRemoteWorkspaceCreation(provider: provider, workspace: workspace, terminal: nil) }
            throw CancellationError()
        }
        await provider.refresh()
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
        guard let reservation else {
            let opened = try await catalog.projectGroupAsNewLocalWorkspace(
                group,
                title: localWorkspaceTitle(hostName: resolvedMachineName(machine, snapshot: catalog.snapshot), group: group),
                focus: focus,
                host: .appOptimistic
            )
            catalog.bindCloudWorkspace(
                localWorkspaceID: opened.workspaceID,
                machine: machine,
                remoteWorkspaceID: workspace.id,
                generatedTitle: localWorkspaceTitle(hostName: resolvedMachineName(machine, snapshot: catalog.snapshot), group: group)
            )
            if focus, let first = opened.projections.first { SurfacePaneFactory.focus(panelID: first.panelID, in: first.workspaceID) }
            committed = true
            return (workspace, terminal, opened)
        }
        guard isLiveReservation(reservation) else {
            if createdRemoteTerminal || createdRemoteWorkspace {
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
            optimistic: .app
        )
        if let loadingWorkspace = Workspace.liveWorkspace(id: reservation.workspaceID),
           loadingWorkspace.panels[reservation.loadingPanelID] != nil {
            SurfacePaneFactory.close(panelID: reservation.loadingPanelID, in: reservation.workspaceID)
        } else {
            if createdRemoteTerminal || createdRemoteWorkspace {
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
           let manager = AppDelegate.shared?.tabManagerFor(tabId: reservation.workspaceID) {
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
        catalog: SurfaceCatalog
    ) -> LocalWorkspaceReservation? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        let preferredWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let context = appDelegate.contextForMainWindow(preferredWindow)
            ?? appDelegate.preferredMainWindowContextForWorkspaceCreation(
                debugSource: "cloudWorkspace.optimisticReservation"
            )
        guard let tabManager = context?.tabManager
            ?? appDelegate.activeTabManagerForCommands(preferredWindow: preferredWindow),
              let workspace = tabManager.addWorkspaceIfActive(
                title: String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM"),
                titleSource: .auto,
                initialSurface: .cloudVMLoading,
                inheritWorkingDirectory: false,
                select: focus,
                autoWelcomeIfNeeded: false
              ),
              let loadingPanel = workspace.panels.values.compactMap({ $0 as? CloudVMLoadingPanel }).first else {
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
    private static func rollbackLocalWorkspace(_ reservation: LocalWorkspaceReservation) {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: reservation.workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == reservation.workspaceID }),
              workspace.effectiveCustomTitleSource != .user,
              workspace.panels.count == 1,
              workspace.panels[reservation.loadingPanelID] is CloudVMLoadingPanel else { return }
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
