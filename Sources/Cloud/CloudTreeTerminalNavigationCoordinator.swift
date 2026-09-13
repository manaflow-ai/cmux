import Foundation

/// Routes an ordinary Cloud tree terminal activation to its parent workspace.
/// The coordinator restores a closed workspace as one local layout, or reuses
/// an existing projection, before focusing the exact clicked daemon tab.
@MainActor
final class CloudTreeTerminalNavigationCoordinator {
    typealias Run = @MainActor (
        _ label: String,
        _ operation: @escaping @MainActor (SurfaceCatalog) async throws -> Void
    ) -> Task<Void, Never>

    private let machineName: @MainActor (SurfaceMachineID) -> String
    private let run: Run
    private let operationController: CloudWorkspaceOperationController?

    init(
        machineName: @escaping @MainActor (SurfaceMachineID) -> String,
        run: @escaping Run,
        operationController: CloudWorkspaceOperationController?
    ) {
        self.machineName = machineName
        self.run = run
        self.operationController = operationController
    }

    /// Opens the parent Cloud workspace and focuses the clicked terminal view.
    /// Duplicate activations for one remote workspace share one keyed operation.
    func open(
        machine: SurfaceMachineID,
        group: SurfaceResourceGroup,
        resource: SurfaceResourceID,
        view: SurfaceRemoteView?,
        openIn: UUID?
    ) {
        guard machine == resource.machine,
              let remoteWorkspaceID = view?.workspace.id ?? group.remoteWorkspaceID,
              !remoteWorkspaceID.isEmpty,
              group.remoteWorkspaceID == nil || group.remoteWorkspaceID == view?.workspace.id else {
            return
        }
        let key = "cloud-terminal:\(machine.rawValue):\(remoteWorkspaceID)"
        let operation: @MainActor () async -> Void = { [weak self] in
            guard let self else { return }
            let task = self.run(
                String(
                    format: String(localized: "cloudTree.operation.project", defaultValue: "Opening on %@\u{2026}"),
                    self.machineName(machine)
                )
            ) { catalog in
                try await self.navigate(
                    catalog: catalog,
                    machine: machine,
                    group: group.withRemoteWorkspaceID(remoteWorkspaceID),
                    resource: resource,
                    view: view,
                    remoteWorkspaceID: remoteWorkspaceID,
                    openIn: openIn
                )
            }
            await task.value
        }
        if let operationController {
            _ = operationController.start(key: key, operation)
        } else {
            Task { @MainActor in await operation() }
        }
    }

    private func navigate(
        catalog: SurfaceCatalog,
        machine: SurfaceMachineID,
        group: SurfaceResourceGroup,
        resource: SurfaceResourceID,
        view: SurfaceRemoteView?,
        remoteWorkspaceID: String,
        openIn: UUID?
    ) async throws {
        let localWorkspaceID = CloudTreeNodeBuilder.localWorkspaceShowing(
            remoteWorkspaceID: remoteWorkspaceID,
            placements: group.placements,
            snapshot: catalog.snapshot
        ) ?? openIn
        if let localWorkspaceID {
            let opened: (projection: SurfaceProjection, reused: Bool)
            if let view {
                opened = try await catalog.project(
                    resource,
                    into: .workspace(id: localWorkspaceID, placement: .tab),
                    focus: true,
                    reuseExisting: true,
                    reuseInWorkspace: localWorkspaceID,
                    remoteView: view
                )
            } else {
                opened = try await catalog.project(
                    resource,
                    into: .workspace(id: localWorkspaceID, placement: .tab),
                    focus: true,
                    reuseExisting: true,
                    reuseInWorkspace: localWorkspaceID
                )
            }
            SurfacePaneFactory.focus(
                panelID: opened.projection.panelID,
                in: opened.projection.workspaceID
            )
            return
        }

        let layout = await CloudWorkspaceLayoutTranslator.fetch(
            machine: machine,
            workspaceID: remoteWorkspaceID,
            catalog: catalog
        )
        let opened = try await catalog.projectGroupAsNewLocalWorkspace(
            group,
            title: CloudTreeNodeActions.localWorkspaceTitle(
                hostName: machineName(machine),
                group: group
            ),
            focus: true,
            host: .app,
            layout: layout
        )
        guard !Task.isCancelled else {
            closeOpenedWorkspace(opened.workspaceID)
            throw CancellationError()
        }
        catalog.bindCloudWorkspace(
            localWorkspaceID: opened.workspaceID,
            machine: machine,
            remoteWorkspaceID: remoteWorkspaceID,
            generatedTitle: CloudTreeNodeActions.localWorkspaceTitle(
                hostName: machineName(machine),
                group: group
            )
        )
        guard let target = targetProjection(
            in: opened.projections,
            resource: resource,
            view: view,
            remoteWorkspaceID: remoteWorkspaceID
        ) else {
            closeOpenedWorkspace(opened.workspaceID)
            throw SurfaceCatalogError.destinationNotFound(
                String(localized: "cloudTree.error.terminalRestoreFailed", defaultValue: "The clicked Cloud terminal could not be restored in its workspace.")
            )
        }
        SurfacePaneFactory.focus(panelID: target.panelID, in: target.workspaceID)
    }

    private func targetProjection(
        in projections: [SurfaceProjection],
        resource: SurfaceResourceID,
        view: SurfaceRemoteView?,
        remoteWorkspaceID: String
    ) -> SurfaceProjection? {
        let matches = projections.filter { projection in
            guard projection.resource == resource,
                  projection.remoteWorkspaceID == remoteWorkspaceID else { return false }
            guard let view else { return projection.remoteTabID == nil }
            return projection.remoteTabID == view.tabID
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func closeOpenedWorkspace(_ workspaceID: UUID) {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
            return
        }
        _ = manager.closeWorkspaceNonInteractively(
            workspace,
            recordHistory: false,
            allowPinned: true
        )
    }
}

extension CloudTreeOutlineView.Coordinator {
    /// Resolves a terminal row's workspace parent before dispatching its open verb.
    func openTerminalRow(_ node: CloudTreeNode, row: CloudTreeTerminalRow) {
        if let parent = outlineView?.parent(forItem: node) as? CloudTreeNode,
           case .workspace(let machine, let workspace, _, _, let openIn) = parent.kind {
            guard machine == row.resource.machine,
                  let group = parent.dragGroup,
                  group.remoteWorkspaceID == workspace.id,
                  row.remoteView?.workspace.id == nil || row.remoteView?.workspace.id == workspace.id else {
                #if DEBUG
                cmuxDebugLog("cloudTree.open terminal staleOwner resource=\(row.resource.id.rawValue)")
                #endif
                return
            }
            nodeActions.openRemoteTerminal(machine, group, row.resource.id, row.remoteView, openIn)
        } else if let view = row.remoteView {
            #if DEBUG
            cmuxDebugLog("cloudTree.open terminal missingOwner resource=\(row.resource.id.rawValue) view=\(view.tabID)")
            #endif
        } else {
            // Pool terminals have no owner; retain their selected-workspace behavior.
            nodeActions.project(row.resource.id, .tab, true)
        }
    }
}
