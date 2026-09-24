import CmuxSurfaceCatalogModel
import Foundation

/// Routes an ordinary Cloud tree terminal activation to its parent workspace.
/// The coordinator restores a closed workspace as one local layout, or reuses
/// an existing projection, before focusing the exact clicked daemon tab.
@MainActor
final class CloudTreeTerminalNavigationCoordinator {
    typealias Run = @MainActor (
        _ label: String,
        _ operation: @escaping @MainActor (any CloudTerminalNavigationCatalog) async throws -> Void
    ) -> Task<Void, Never>

    private let machineName: @MainActor (SurfaceMachineID) -> String
    private let run: Run
    private let host: CloudTerminalNavigationHost
    private let operationController: (any CloudTerminalNavigationScheduling)?

    init(
        machineName: @escaping @MainActor (SurfaceMachineID) -> String,
        run: @escaping Run,
        host: CloudTerminalNavigationHost,
        operationController: (any CloudTerminalNavigationScheduling)?
    ) {
        self.machineName = machineName
        self.run = run
        self.host = host
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
        catalog: any CloudTerminalNavigationCatalog,
        machine: SurfaceMachineID,
        group: SurfaceResourceGroup,
        resource: SurfaceResourceID,
        view: SurfaceRemoteView?,
        remoteWorkspaceID: String,
        openIn: UUID?
    ) async throws {
        try catalog.checkCloudWorkspaceNavigation(machine: machine, workspaceID: remoteWorkspaceID)
        let localWorkspaceID = catalog.localWorkspaceShowing(
            remoteWorkspaceID: remoteWorkspaceID,
            placements: group.placements
        ) ?? openIn
        if let localWorkspaceID {
            let projection = try await catalog.projectTerminal(resource, in: localWorkspaceID, view: view)
            host.focus(projection.panelID, projection.workspaceID)
            return
        }

        let layout = await catalog.terminalWorkspaceLayout(
            machine: machine,
            workspaceID: remoteWorkspaceID
        )
        try catalog.checkCloudWorkspaceNavigation(machine: machine, workspaceID: remoteWorkspaceID)
        let opened = try await catalog.openTerminalWorkspace(
            group,
            title: group.localWorkspaceTitle(hostName: machineName(machine)),
            layout: layout
        )
        guard !Task.isCancelled else {
            host.closeWorkspace(opened.workspaceID)
            throw CancellationError()
        }
        catalog.bindTerminalWorkspace(
            localWorkspaceID: opened.workspaceID,
            machine: machine,
            remoteWorkspaceID: remoteWorkspaceID,
            generatedTitle: group.localWorkspaceTitle(hostName: machineName(machine))
        )
        guard let target = targetProjection(
            in: opened.projections,
            resource: resource,
            view: view,
            remoteWorkspaceID: remoteWorkspaceID
        ) else {
            host.closeWorkspace(opened.workspaceID)
            throw SurfaceCatalogError.destinationNotFound(
                String(localized: "cloudTree.error.terminalRestoreFailed", defaultValue: "The clicked Cloud terminal could not be restored in its workspace.")
            )
        }
        host.focus(target.panelID, target.workspaceID)
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
}
