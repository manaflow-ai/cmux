import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// Owns the shared pending workspace projection; both sidebars consume its receipt identity.
@MainActor
final class CloudWorkspaceCreationCoordinator {
    private weak var catalog: SurfaceCatalog?
    private(set) var operations: [UUID: CloudWorkspaceCreationOperation] = [:]
    /// Tree reveals for creates their window selected, withdrawn when the create fails.
    let reveals = CloudWorkspaceCreationReveals()
    init(catalog: SurfaceCatalog) {
        self.catalog = catalog
    }

    func create(
        provider: any SurfaceProvider, name: String?, focus: Bool, host: CloudWorkspaceCreationHost?, reuseFailedCreation: Bool,
        existingWorkspace: SurfaceRemoteWorkspace?, existingTerminal: SurfaceResource?,
        existingRemoteView: SurfaceRemoteView? = nil,
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
        operation.existingRemoteView = existingRemoteView
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

    /// Opens an already-authoritative Cloud workspace through the same local
    /// admission owner as workspace creation. The local loading pane and
    /// binding are published before the first materialization await; terminal
    /// rows use the exact placement when one is available, while display or
    /// browser-only workspaces project their whole group behind that pane.
    func openExistingWorkspace(
        provider: any SurfaceProvider,
        workspace: SurfaceRemoteWorkspace,
        group: SurfaceResourceGroup,
        focus: Bool,
        host: CloudWorkspaceCreationHost,
        existingRemoteView: SurfaceRemoteView? = nil,
        validateOperation: @escaping @MainActor () throws -> Void = { try Task.checkCancellation() }
    ) async throws -> (workspaceID: UUID, projections: [SurfaceProjection]) {
        guard let catalog, catalog.provider(for: provider.machine) === provider else { throw CancellationError() }
        guard group.representsWorkspace,
              group.remoteWorkspaceID == workspace.id,
              group.placements.allSatisfy({ placement in
                  placement.resource.machine == provider.machine
                      && (placement.remoteWorkspaceID == nil || placement.remoteWorkspaceID == workspace.id)
        }) else { throw CancellationError() }
        try validateOperation()
        if let local = host.manager?.tabs.first(where: { candidate in
            candidate.cloudVMBinding?.vmID == provider.machine.rawValue
                && candidate.cloudVMBinding?.remoteWorkspaceID == workspace.id
        }) {
            let projections = catalog.projections.filter { $0.workspaceID == local.id }
            if !projections.isEmpty {
                if focus, let manager = host.manager {
                    manager.selectWorkspace(local)
                }
                return (local.id, Array(projections))
            }
        }
        if let existing = catalog.cloudWorkspaceProjectionCoordinator.environment.bindings().first(where: { localID, binding in
            binding.vmID == provider.machine.rawValue
                && binding.remoteWorkspaceID == workspace.id
                && Workspace.liveWorkspace(id: localID)?.owningTabManager === host.manager
        }) {
            let projections = catalog.projections.filter { $0.workspaceID == existing.key }
            if !projections.isEmpty {
                if focus, let local = Workspace.liveWorkspace(id: existing.key), let manager = host.manager {
                    manager.selectWorkspace(local)
                }
                return (existing.key, Array(projections))
            }
        }
        if let pending = operations.values.first(where: {
            $0.isExistingWorkspaceOpen && $0.provider === provider
                && $0.receipt?.workspace.id == workspace.id
                && $0.host?.manager === host.manager
        }), let reservation = pending.reservation {
            if focus, let local = Workspace.liveWorkspace(id: reservation.workspaceID) {
                pending.host?.manager?.selectWorkspace(local)
            }
            return (reservation.workspaceID, pending.openedProjections)
        }
        let operation = CloudWorkspaceCreationOperation(
            provider: provider,
            host: host,
            allowsActionRetry: false,
            validateOperation: validateOperation
        )
        operation.isExistingWorkspaceOpen = true
        operation.existingRemoteView = existingRemoteView
        operation.pendingWorkspaceGroup = group
        operation.receipt = SurfaceWorkspaceCreationReceipt(workspace: workspace, terminal: nil, cursor: nil)
        operations[operation.id] = operation
        return try await withTaskCancellationHandler {
            try await performExistingWorkspaceOpen(operation, focus: focus, catalog: catalog)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(operation.id) }
        }
    }

    /// The pending local identity is the row's projection fence. Callers use
    /// it to make a repeated activation a navigation, even before the next
    /// catalog notification repaints the tree.
    func pendingLocalWorkspaceID(
        machine: SurfaceMachineID,
        remoteWorkspaceID: String,
        manager: TabManager?
    ) -> UUID? {
        operations.values.first {
            $0.isExistingWorkspaceOpen && $0.machine == machine && $0.receipt?.workspace.id == remoteWorkspaceID
                && $0.host?.manager === manager
        }?.reservation?.workspaceID
    }

    /// Performs one existing-workspace admission and reconciles its first projection.
    private func performExistingWorkspaceOpen(
        _ operation: CloudWorkspaceCreationOperation,
        focus: Bool,
        catalog: SurfaceCatalog
    ) async throws -> (workspaceID: UUID, projections: [SurfaceProjection]) {
        operation.isRunning = true
        operation.failure = nil
        defer { operation.isRunning = false }
        do {
            try check(operation, catalog: catalog)
            guard let host = operation.host,
                  let receipt = operation.receipt,
                  let group = operation.pendingWorkspaceGroup else { throw CancellationError() }
            let resourcesByID = Dictionary(
                uniqueKeysWithValues: catalog.snapshot.resources.map { ($0.id, $0) }
            )
            let firstTerminal: (resource: SurfaceResource, placement: SurfaceResourcePlacement, view: SurfaceRemoteView?)? = group.placements.compactMap { placement in
                guard let resource = resourcesByID[placement.resource],
                      resource.kind == .terminal else { return nil }
                let view = operation.existingRemoteView ?? (try? catalog.remoteView(
                    for: resource.id,
                    tabID: placement.remoteTabID,
                    workspaceID: placement.remoteWorkspaceID ?? receipt.workspace.id
                )) ?? placement.remoteTabID.flatMap { tabID in resource.remoteViews?.first { $0.tabID == tabID } }
                return (resource, placement, view)
            }.first
            let reservationReceipt = SurfaceWorkspaceCreationReceipt(
                workspace: receipt.workspace,
                terminal: firstTerminal?.resource,
                cursor: nil
            )
            let reservation = try host.reserve(
                title: String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM"),
                machine: operation.machine,
                receipt: reservationReceipt,
                // Keep the provisional workspace out of view while its full
                // remote graph is materialized. Selecting it here exposes the
                // starter pane before the layout transaction below can run.
                focus: false,
                // Input ownership is independent from visible workspace
                // selection. Start the reserved manual runtime immediately
                // when the caller requested focus, even though selection waits
                // until the layout transaction completes.
                startInput: focus,
                remoteView: firstTerminal?.view
            )
            operation.reservation = reservation
            let operationID = operation.id
            reservation.cancel = { [weak self] in self?.cancel(operationID, discardLocal: true) }
            let generatedTitle = CloudTreeNodeActions.localWorkspaceTitle(
                hostName: CloudTreeNodeActions.resolvedMachineName(operation.machine, snapshot: catalog.snapshot),
                group: group
            )
            catalog.bindCloudWorkspace(
                localWorkspaceID: reservation.workspaceID,
                machine: operation.machine,
                remoteWorkspaceID: receipt.workspace.id,
                generatedTitle: generatedTitle
            )
            catalog.notifyChange()
            try check(operation, catalog: catalog)

            var projections: [SurfaceProjection] = []
            if let firstTerminal {
                let opened = try await catalog.project(
                    firstTerminal.resource.id,
                    into: .workspace(id: reservation.workspaceID, placement: .tab),
                    focus: false,
                    reuseExisting: false,
                    remoteView: firstTerminal.view,
                    adopting: reservation
                )
                operation.terminal = firstTerminal.resource
                projections.append(opened.projection)
                // Publish each accepted placement to the transaction before the
                // next await. If a later placement fails, rollback must retire
                // the panes already materialized in this local workspace.
                operation.openedProjections = projections
                try check(operation, catalog: catalog)
                operation.reservation?.creationReceipt.finish(.success(firstTerminal.resource))
                let remaining = group.placements.filter { $0 != firstTerminal.placement }
                if !remaining.isEmpty {
                    let rest = try await catalog.projectGroup(
                        SurfaceResourceGroup(
                            title: group.title,
                            placements: remaining,
                            remoteWorkspaceID: group.remoteWorkspaceID,
                            // This is an intentional subset after the first
                            // terminal adopted the reservation. Re-resolving it
                            // as a whole workspace would project the first tab
                            // again and defeat stable placement identity.
                            representsWorkspace: false
                        ),
                        into: .workspace(id: reservation.workspaceID, placement: .tab),
                        focus: false
                    )
                    guard rest.count == remaining.count else {
                        throw SurfaceCatalogError.destinationNotFound("workspace placement incomplete")
                    }
                    projections.append(contentsOf: rest)
                    operation.openedProjections = projections
                }
            } else {
                projections = try await catalog.projectGroup(
                    group,
                    into: .workspace(id: reservation.workspaceID, placement: .split),
                    focus: false
                )
            }
            guard !projections.isEmpty else { throw SurfaceCatalogError.destinationNotFound("empty group") }
            operation.openedProjections = projections
            try check(operation, catalog: catalog)
            // The workspace was populated as one local admission. Apply the
            // accepted remote geometry before completing the reservation, so a
            // newly opened workspace never paints the temporary tab layout and
            // then visibly moves its panes when reconciliation catches up.
            if let layout = catalog.cloudWorkspaceLayout(machine: operation.machine, workspaceID: receipt.workspace.id),
               let workspace = Workspace.liveWorkspace(id: reservation.workspaceID) {
                workspace.applyCloudWorkspaceLayout(
                    layout.includingMissingPlacements(group.placements),
                    projections: projections
                )
            }
            // Commit the request before retiring its loading reservation. A
            // synchronous pane teardown must never cancel an accepted open.
            operation.isComplete = true
            operations[operation.id] = nil
            catalog.notifyChange()
            host.complete(reservation, projection: projections[0])
            if focus, let manager = host.manager,
               manager.selectedTabId == host.selectedWorkspaceID,
               manager.window?.isKeyWindow != false,
               let workspace = Workspace.liveWorkspace(id: reservation.workspaceID) {
                manager.selectWorkspace(workspace)
                SurfacePaneFactory.focus(panelID: projections[0].panelID, in: workspace.id)
            }
            catalog.requestCloudWorkspaceProjection(reservation.workspaceID)
            await catalog.cloudWorkspaceProjectionCoordinator.waitForIdle()
            return (reservation.workspaceID, projections)
        } catch {
            // Existing Cloud resources are never owned by this local-open
            // request. Remove any partial projections with the replacement
            // reason before closing the admitted workspace, so rollback does
            // not send remote close-tab mutations.
            let partial = operation.openedProjections
            let reservation = operation.reservation
            let wasInvalidated = operations[operation.id] !== operation
                || operation.host?.isAvailable == false
                || catalog.provider(for: operation.machine) !== operation.provider
            operations[operation.id] = nil
            if let reservation {
                // Retire the reserved pane first. Closing its last panel can
                // otherwise create a replacement local shell before the host
                // gets a chance to remove the admitted workspace.
                operation.host?.discard(reservation, catalog: catalog)
            }
            for projection in partial {
                catalog.endProjections(panelID: projection.panelID, reason: .replaced)
                if let workspace = Workspace.liveWorkspace(id: projection.workspaceID),
                   workspace.panels[projection.panelID] != nil {
                    catalog.withProjectionEndReason(for: [projection.panelID], reason: .replaced) {
                        _ = workspace.closePanel(projection.panelID, force: true)
                    }
                }
            }
            catalog.notifyChange()
            if wasInvalidated || error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
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
            let canRetainForRetry = !operation.isExistingWorkspaceOpen
                && !(error is CancellationError)
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
            withdrawReveal(operation)
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
            let provisionalReceipt = operation.isExistingWorkspaceOpen
                ? operation.receipt ?? existingWorkspace.map {
                    SurfaceWorkspaceCreationReceipt(workspace: $0, terminal: existingTerminal, cursor: nil)
                }
                : nil
            let reservation = try host.reserve(
                title: provisionalTitle,
                machine: operation.machine,
                receipt: provisionalReceipt,
                focus: focus,
                remoteView: operation.existingRemoteView
            )
            operation.reservation = reservation
            if focus, let manager = host.manager, manager.selectedTabId == reservation.workspaceID {
                operation.revealToken = reveals.begin(in: manager)
            }
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
            // Navigating away while the daemon allocated hands the tree back to the user.
            if let token = operation.revealToken {
                if host.manager?.selectedTabId == reservation.workspaceID {
                    reveals.receive(token, machine: operation.machine, remoteWorkspaceID: receipt.workspace.id)
                } else {
                    reveals.withdraw(token)
                }
            }
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
        let view = operation.existingRemoteView
            ?? terminal.remoteViews?.first { $0.workspace.id == receipt.workspace.id }
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
            if operation.isExistingWorkspaceOpen,
               let state = catalog.cloudStates[operation.machine],
               catalog.cloudStateObservations[operation.machine]?.freshness == .current,
               !state.workspaceIDs.contains(receipt.workspace.id) {
                throw CancellationError()
            }
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
                if operation.isExistingWorkspaceOpen && !state.workspaceIDs.contains(receipt.workspace.id) {
                    reject(operation)
                } else if operation.isComplete, operation.isConfirmed(in: state) {
                    operations[operation.id] = nil
                }
                continue
            }
            guard let cursor = state.cursor else { reject(operation); continue }
            if cursor.generation != fence.generation || (cursor.revision >= fence.revision && !state.workspaceIDs.contains(receipt.workspace.id)) {
                reject(operation)
            } else if operation.terminal != nil,
                      let terminalFence = operation.terminalCursor ?? (receipt.terminal == nil ? nil : receipt.cursor),
                      cursor.generation == terminalFence.generation, cursor.revision >= terminalFence.revision,
                      !operation.containsStarter(in: state) {
                reject(operation)
            } else if operation.isComplete, operation.isConfirmed(in: state) {
                operations[operation.id] = nil
            }
        }
    }

    func cancel(_ id: UUID, discardLocal: Bool = true, discardRemote: Bool = true) {
        guard let operation = operations.removeValue(forKey: id), let catalog else { return }
        // A finished create keeps its reveal through pane close or teardown.
        if !operation.isComplete { withdrawReveal(operation) }
        operation.retryTask?.cancel()
        if discardLocal, let reservation = operation.reservation { operation.host?.discard(reservation, catalog: catalog) }
        if discardRemote, !operation.isComplete {
            Task { @MainActor [weak self] in
                await self?.cleanupRemoteResources(operation)
            }
        }
        catalog.notifyChange()
    }

    /// The daemon rejected the create, even after it finished: it lost its cursor, changed
    /// generation, or dropped the receipt's workspace or starter.
    private func reject(_ operation: CloudWorkspaceCreationOperation) {
        withdrawReveal(operation)
        cancel(operation.id)
    }

    private func withdrawReveal(_ operation: CloudWorkspaceCreationOperation) {
        if let token = operation.revealToken { reveals.withdraw(token) }
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
