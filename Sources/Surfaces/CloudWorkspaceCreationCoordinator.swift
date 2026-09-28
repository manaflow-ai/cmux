import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// Owns the shared pending workspace projection; both sidebars consume its receipt identity.
@MainActor
final class CloudWorkspaceCreationCoordinator {
    private weak var catalog: SurfaceCatalog?
    private(set) var operations: [UUID: CloudWorkspaceCreationOperation] = [:]
    init(catalog: SurfaceCatalog) {
        self.catalog = catalog
    }

    func create(
        provider: any SurfaceProvider, name: String?, focus: Bool, host: CloudWorkspaceCreationHost?, reuseFailedCreation: Bool,
        existingWorkspace: SurfaceRemoteWorkspace?, existingTerminal: SurfaceResource?,
        validateOperation: @escaping @MainActor () throws -> Void = { try Task.checkCancellation() }
    ) async throws -> (workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource, opened: (workspaceID: UUID, projections: [SurfaceProjection])?) {
        guard let catalog, catalog.provider(for: provider.machine) === provider else { throw CancellationError() }
        try validateOperation()
        let failed = operations.values.filter {
            reuseFailedCreation && $0.allowsActionRetry && $0.provider === provider && !$0.isRunning
                && $0.failure != nil && $0.host?.manager === host?.manager
        }
        // An ambiguous pair of failed intents must be retried from its own pane;
        // never guess which concurrent request a new action meant to recover.
        let retained = failed.count == 1 ? failed.first : nil
        let operation = retained ?? CloudWorkspaceCreationOperation(
            provider: provider, host: host, allowsActionRetry: reuseFailedCreation,
            validateOperation: validateOperation
        )
        operation.validateOperation = validateOperation
        operations[operation.id] = operation
        return try await withTaskCancellationHandler {
            try await perform(operation, name: name, focus: focus, existingWorkspace: existingWorkspace,
                              existingTerminal: existingTerminal, catalog: catalog)
        } onCancel: {
            // The synchronous cancellation callback only hops to this actor;
            // perform's catch also owns the same idempotent cleanup on unwind.
            Task { @MainActor [weak self] in self?.cancel(operation.id) }
        }
    }

    private func perform(
        _ operation: CloudWorkspaceCreationOperation, name: String?, focus: Bool,
        existingWorkspace: SurfaceRemoteWorkspace?, existingTerminal: SurfaceResource?, catalog: SurfaceCatalog
    ) async throws -> (workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource, opened: (workspaceID: UUID, projections: [SurfaceProjection])?) {
        operation.isRunning = true
        operation.failure = nil
        defer { operation.isRunning = false }
        if let reservation = operation.reservation { operation.host?.restart(reservation) }
        do {
            return try await run(operation, name: name, focus: focus, existingWorkspace: existingWorkspace,
                                 existingTerminal: existingTerminal, catalog: catalog)
        } catch {
            let canRetainForRetry = !(error is CancellationError)
                && !Task.isCancelled
                && operations[operation.id] === operation
                && operation.reservation.map { operation.host?.isLive($0) == true } == true
            guard canRetainForRetry,
                  let reservation = operation.reservation else {
                // A provider/auth/backend error before local admission must
                // remain visible to the caller. Only cancellation or a request
                // invalidated by teardown is translated to CancellationError;
                // otherwise CloudTreeNodeActions and socket callers lose the
                // diagnostic they are responsible for presenting.
                let wasInvalidated = error is CancellationError
                    || Task.isCancelled
                    || operations[operation.id] !== operation
                    || operation.host?.isAvailable == false
                await cleanupRemoteResources(operation)
                cancel(operation.id, discardRemote: false)
                if wasInvalidated { throw CancellationError() }
                throw error
            }
            // Creation committed; retain its identity and input for an explicit
            // reconnect. Only this request's retry may reuse its remote receipt.
            operation.failure = error
            operation.host?.fail(reservation, error: error)
            let id = operation.id
            reservation.retry = { [weak self] in self?.retry(id) }
            catalog.notifyChange()
            throw error
        }
    }

    private func retry(_ id: UUID) {
        guard let catalog, let operation = operations[id], operation.failure != nil,
              !operation.isRunning, operation.retryTask == nil else { return }
        operation.isRunning = true
        operation.retryTask = Task { @MainActor [weak self] in
            defer { operation.retryTask = nil }
            guard let self else { return }
            _ = try? await self.perform(operation, name: nil, focus: false, existingWorkspace: nil,
                                       existingTerminal: nil, catalog: catalog)
        }
    }

    private func run(
        _ operation: CloudWorkspaceCreationOperation, name: String?, focus: Bool,
        existingWorkspace: SurfaceRemoteWorkspace?, existingTerminal: SurfaceResource?,
        catalog: SurfaceCatalog
    ) async throws -> (workspace: SurfaceRemoteWorkspace, terminal: SurfaceResource, opened: (workspaceID: UUID, projections: [SurfaceProjection])?) {
        try check(operation, catalog: catalog)
        if let host = operation.host, operation.reservation == nil {
            // Admit the local manual pane before the first remote await. It is
            // the request's early-input owner while the daemon allocates the
            // workspace and starter terminal behind it.
            let provisionalTitle = String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM")
            let reservation = try host.reserve(
                title: provisionalTitle,
                machine: operation.machine,
                focus: focus
            )
            operation.reservation = reservation
            let operationID = operation.id
            reservation.cancel = { [weak self] in self?.cancel(operationID, discardLocal: false) }
            // Bind the local workspace to its machine immediately. The remote
            // workspace ID is filled from the receipt later, but selection and
            // Cmd+N must already recognize this pane as Cloud-owned while it
            // waits for the daemon.
            catalog.bindCloudWorkspace(
                localWorkspaceID: reservation.workspaceID,
                machine: operation.machine,
                remoteWorkspaceID: nil,
                generatedTitle: provisionalTitle
            )
            catalog.notifyChange()
            try check(operation, catalog: catalog)
        }
        let receipt: SurfaceWorkspaceCreationReceipt
        if let retained = operation.receipt {
            receipt = retained
        } else if let existingWorkspace {
            receipt = SurfaceWorkspaceCreationReceipt(workspace: existingWorkspace, terminal: existingTerminal, cursor: nil)
            operation.ownsRemoteWorkspace = false
            operation.ownsRemoteTerminal = false
        } else {
            // The shared admission boundary is the daemon's identity receipt,
            // not PTY attachment or shell readiness. Before it, the existing
            // workspace retains input ownership; afterwards the manual pane does.
            receipt = try await operation.provider.createRemoteWorkspaceReceipt(name: name)
            operation.ownsRemoteWorkspace = true
            operation.ownsRemoteTerminal = receipt.terminal != nil
        }
        if let reservation = operation.reservation,
           let host = operation.host {
            let generatedTitle = CloudTreeNodeActions.localWorkspaceTitle(
                hostName: CloudTreeNodeActions.resolvedMachineName(operation.machine, snapshot: catalog.snapshot),
                group: SurfaceResourceGroup(title: receipt.workspace.name, resources: [])
            )
            host.updateReservation(reservation, receipt: receipt, generatedTitle: generatedTitle, catalog: catalog)
            catalog.bindCloudWorkspace(
                localWorkspaceID: reservation.workspaceID,
                machine: operation.machine,
                remoteWorkspaceID: receipt.workspace.id,
                generatedTitle: generatedTitle
            )
        }
        // Retain the provider's identity receipt before the next cancellation
        // fence. A provider may return a committed remote resource after the
        // task was cancelled; cleanup must still know exactly which IDs this
        // operation owns.
        operation.receipt = receipt
        try check(operation, catalog: catalog)
        catalog.notifyChange()
        // Older daemons may supply a starter only through their first snapshot.
        // The native reservation is already visible while that discovery runs.
        if receipt.terminal == nil, existingTerminal == nil, operation.terminal == nil { await operation.provider.refresh() }
        try check(operation, catalog: catalog)
        let existing = operation.terminal ?? existingTerminal ?? receipt.terminal ?? catalog.snapshot.resources(on: operation.machine).first {
            $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == receipt.workspace.id }
        }
        let terminal: SurfaceResource
        if let existing {
            terminal = existing
            if operation.ownsRemoteWorkspace { operation.ownsRemoteTerminal = true }
        } else {
            terminal = try await operation.provider.createTerminal(
                command: nil, cwd: nil, name: nil, remoteWorkspaceID: receipt.workspace.id, request: operation.terminalRequest
            )
            operation.ownsRemoteTerminal = true
        }
        // Record the identity before validation can throw so cancellation or a
        // stale placement still cleans the terminal this operation created.
        operation.terminal = terminal
        try check(operation, catalog: catalog)
        try operation.reservation?.sourcePlacement.validate(created: terminal)
        operation.reservation?.creationReceipt.finish(.success(terminal))
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
        // A provider may create a different pane instead of adopting the reservation.
        // Commit before its native teardown reports projectionDidEnd, so retiring
        // the placeholder cannot cancel and delete the accepted remote workspace.
        finish(operation, catalog: catalog)
        host.complete(reservation, projection: opened.projection)
        return (receipt.workspace, terminal, (reservation.workspaceID, [opened.projection]))
    }

    private func check(_ operation: CloudWorkspaceCreationOperation, catalog: SurfaceCatalog) throws {
        try operation.validateOperation()
        try Task.checkCancellation()
        guard operations[operation.id] === operation,
              catalog.provider(for: operation.machine) === operation.provider else { throw CancellationError() }
        if let host = operation.host, !host.isAvailable { throw CancellationError() }
        if let receipt = operation.receipt {
            try catalog.checkCloudWorkspaceNavigation(machine: operation.machine, workspaceID: receipt.workspace.id)
        }
        if let reservation = operation.reservation, operation.host?.isLive(reservation) != true { throw CancellationError() }
    }

    private func finish(_ operation: CloudWorkspaceCreationOperation, catalog: SurfaceCatalog) {
        operation.isComplete = true
        if operation.reservation == nil
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
            guard let receipt = operation.receipt else { continue }
            guard let fence = receipt.cursor else {
                if operation.isComplete, operation.isConfirmed(in: state) { operations[operation.id] = nil }
                continue
            }
            guard let cursor = state.cursor else { cancel(operation.id); continue }
            if cursor.generation != fence.generation || (cursor.revision >= fence.revision && !state.workspaceIDs.contains(receipt.workspace.id)) {
                cancel(operation.id)
            } else if operation.terminal != nil,
                      let terminalFence = operation.terminalCursor ?? (receipt.terminal == nil ? nil : receipt.cursor),
                      cursor.generation == terminalFence.generation, cursor.revision >= terminalFence.revision,
                      !operation.containsStarter(in: state) {
                cancel(operation.id)
            } else if operation.isComplete, operation.isConfirmed(in: state) {
                operations[operation.id] = nil
            }
        }
    }

    func cancel(_ id: UUID, discardLocal: Bool = true, discardRemote: Bool = true) {
        guard let operation = operations.removeValue(forKey: id), let catalog else { return }
        operation.retryTask?.cancel()
        if discardLocal, let reservation = operation.reservation { operation.host?.discard(reservation, catalog: catalog) }
        if discardRemote, !operation.isComplete {
            Task { @MainActor [weak self] in
                await self?.cleanupRemoteResources(operation)
            }
        }
        catalog.notifyChange()
    }

    private func cleanupRemoteResources(_ operation: CloudWorkspaceCreationOperation) async {
        guard !operation.remoteCleanupStarted else { return }
        // Pane teardown can cancel while the provider is still suspended
        // before its receipt returns. Do not consume the one-shot cleanup gate
        // until this operation has actually published an owned remote ID; the
        // later catch path will retry cleanup after that receipt arrives.
        guard operation.ownsRemoteWorkspace || operation.ownsRemoteTerminal else { return }
        operation.remoteCleanupStarted = true
        if operation.ownsRemoteTerminal, let terminal = operation.terminal ?? operation.receipt?.terminal {
            try? await operation.provider.closeTerminal(terminal.id)
        }
        if operation.ownsRemoteWorkspace, let workspace = operation.receipt?.workspace {
            try? await operation.provider.closeRemoteWorkspace(id: workspace.id)
        }
    }

    func projectionDidEnd(panelID: UUID) {
        for operation in Array(operations.values) where operation.reservation?.panelID == panelID {
            cancel(operation.id, discardLocal: false)
        }
    }

    func cancel(machine: SurfaceMachineID, workspaceID: String? = nil) {
        for operation in Array(operations.values) where operation.machine == machine
            && (workspaceID == nil || operation.receipt?.workspace.id == workspaceID) {
            cancel(operation.id)
        }
    }

    /// Called synchronously by account/team teardown, before another scope can
    /// admit work. A delayed global notification must never cancel a new request.
    func cancelAll() {
        for id in Array(operations.keys) { cancel(id) }
    }

}
