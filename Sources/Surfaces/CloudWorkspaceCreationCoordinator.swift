import Foundation

/// Owns the shared pending workspace projection; both sidebars consume its receipt identity.
@MainActor
final class CloudWorkspaceCreationCoordinator {
    private weak var catalog: SurfaceCatalog?
    private(set) var operations: [UUID: CloudWorkspaceCreationOperation] = [:]
    private let notificationCenter: NotificationCenter
    private var accessObserver: NSObjectProtocol?

    init(catalog: SurfaceCatalog, notificationCenter: NotificationCenter = .default) {
        self.catalog = catalog
        self.notificationCenter = notificationCenter
        accessObserver = notificationCenter.addObserver(forName: .cmuxCloudVMAccessDidEnd, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAll() }
        }
    }

    deinit {
        if let accessObserver { notificationCenter.removeObserver(accessObserver) }
    }

    func create(
        provider: any SurfaceProvider, name: String?, focus: Bool, host: CloudWorkspaceCreationHost?,
        existingWorkspace: SurfaceRemoteWorkspace?, existingTerminal: SurfaceResource?
    ) async throws -> (workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource, opened: (workspaceID: UUID, projections: [SurfaceProjection])?) {
        guard let catalog, catalog.provider(for: provider.machine) === provider else { throw CancellationError() }
        let operation = CloudWorkspaceCreationOperation(provider: provider, host: host)
        operations[operation.id] = operation
        return try await withTaskCancellationHandler {
            do {
                return try await run(operation, name: name, focus: focus, existingWorkspace: existingWorkspace,
                                     existingTerminal: existingTerminal, catalog: catalog)
            } catch {
                cancel(operation.id)
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(operation.id) }
        }
    }

    private func run(
        _ operation: CloudWorkspaceCreationOperation, name: String?, focus: Bool,
        existingWorkspace: SurfaceRemoteWorkspace?, existingTerminal: SurfaceResource?,
        catalog: SurfaceCatalog
    ) async throws -> (workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource, opened: (workspaceID: UUID, projections: [SurfaceProjection])?) {
        try check(operation, catalog: catalog)
        let receipt: SurfaceWorkspaceCreationReceipt
        if let existingWorkspace {
            receipt = SurfaceWorkspaceCreationReceipt(workspace: existingWorkspace, terminal: existingTerminal, cursor: nil)
        } else {
            receipt = try await operation.provider.createRemoteWorkspaceReceipt(name: name)
        }
        try check(operation, catalog: catalog)
        operation.receipt = receipt
        if let host = operation.host {
            let title = CloudTreeNodeActions.localWorkspaceTitle(
                hostName: CloudTreeNodeActions.resolvedMachineName(operation.machine, snapshot: catalog.snapshot),
                group: SurfaceResourceGroup(title: receipt.workspace.name, resources: [])
            )
            let reservation = try host.reserve(title: title, machine: operation.machine, focus: focus)
            operation.reservation = reservation
            let operationID = operation.id
            reservation.cancel = { [weak self] in self?.cancel(operationID, discardLocal: false) }
            catalog.bindCloudWorkspace(localWorkspaceID: reservation.workspaceID, machine: operation.machine,
                                       remoteWorkspaceID: receipt.workspace.id, generatedTitle: title)
        }
        catalog.notifyChange()
        // Older daemons may supply a starter only through their first snapshot.
        // The native reservation is already visible while that discovery runs.
        if receipt.terminal == nil, existingTerminal == nil { await operation.provider.refresh() }
        try check(operation, catalog: catalog)
        let existing = existingTerminal ?? receipt.terminal ?? catalog.snapshot.resources(on: operation.machine).first {
            $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == receipt.workspace.id }
        }
        let terminal: SurfaceResource
        if let existing { terminal = existing } else {
            terminal = try await operation.provider.createTerminal(
                command: nil, cwd: nil, name: nil, remoteWorkspaceID: receipt.workspace.id, request: operation.terminalRequest
            )
        }
        try check(operation, catalog: catalog)
        operation.terminal = terminal
        operation.terminalCursor = catalog.cloudStateObservations[operation.machine]?.pendingWrites?.first {
            $0.kind == .terminalCreate && $0.resource == terminal.id
        }?.receipt
        guard let reservation = operation.reservation, let host = operation.host else {
            finish(operation, catalog: catalog)
            return (receipt.workspace, terminal, nil)
        }
        let view = terminal.remoteViews?.first { $0.workspace.id == receipt.workspace.id }
        let opened = try await catalog.project(
            terminal.id, into: .workspace(id: reservation.workspaceID, placement: .tab),
            focus: false, reuseExisting: false, remoteView: view, adopting: reservation
        )
        do { try check(operation, catalog: catalog) } catch {
            // A provider can ignore cancellation and return after its native owner closed.
            catalog.endProjections(panelID: opened.projection.panelID, reason: .replaced)
            operation.provider.discardMaterialization(opened.projection)
            throw error
        }
        host.complete(reservation, projection: opened.projection)
        finish(operation, catalog: catalog)
        return (receipt.workspace, terminal, (reservation.workspaceID, [opened.projection]))
    }

    private func check(_ operation: CloudWorkspaceCreationOperation, catalog: SurfaceCatalog) throws {
        try Task.checkCancellation()
        guard operations[operation.id] === operation,
              catalog.provider(for: operation.machine) === operation.provider else { throw CancellationError() }
        if let receipt = operation.receipt {
            try catalog.checkCloudWorkspaceNavigation(machine: operation.machine, workspaceID: receipt.workspace.id)
        }
        if let reservation = operation.reservation, operation.host?.isLive(reservation) != true { throw CancellationError() }
    }

    private func finish(_ operation: CloudWorkspaceCreationOperation, catalog: SurfaceCatalog) {
        operation.isComplete = true
        if operation.reservation == nil || operation.receipt?.cursor == nil
            || catalog.cloudStates[operation.machine].map({ operation.isConfirmed(in: $0) }) == true {
            operations[operation.id] = nil
        }
        catalog.notifyChange()
    }

    func isPending(localWorkspaceID: UUID) -> Bool {
        operations.values.contains { $0.reservation?.workspaceID == localWorkspaceID }
    }

    /// A current graph past a receipt can confirm it or prove that it was removed.
    func reconcile(_ state: CloudVMState) {
        guard let catalog, catalog.cloudStateObservations[state.machine]?.freshness == .current else { return }
        for operation in Array(operations.values) where operation.machine == state.machine {
            guard let receipt = operation.receipt, let fence = receipt.cursor, let cursor = state.cursor else { continue }
            if cursor.generation != fence.generation || (cursor.revision >= fence.revision && !state.workspaceIDs.contains(receipt.workspace.id)) {
                cancel(operation.id)
            } else if let terminal = operation.terminal,
                      let terminalFence = operation.terminalCursor ?? (receipt.terminal == nil ? nil : receipt.cursor),
                      cursor.generation == terminalFence.generation, cursor.revision >= terminalFence.revision,
                      state.lookupIndex.terminal(id: terminal.id.key) == nil {
                cancel(operation.id)
            } else if operation.isComplete, operation.isConfirmed(in: state) {
                operations[operation.id] = nil
            }
        }
    }

    func cancel(_ id: UUID, discardLocal: Bool = true) {
        guard let operation = operations.removeValue(forKey: id), let catalog else { return }
        if discardLocal, let reservation = operation.reservation { operation.host?.discard(reservation, catalog: catalog) }
        catalog.notifyChange()
    }

    func cancel(machine: SurfaceMachineID, workspaceID: String? = nil) {
        for operation in Array(operations.values) where operation.machine == machine
            && (workspaceID == nil || operation.receipt?.workspace.id == workspaceID) {
            cancel(operation.id)
        }
    }

    private func cancelAll() {
        for id in Array(operations.keys) { cancel(id) }
    }

}
