import AppKit
import CmuxCloud
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
import Foundation

/// Launches the New Machine flow in-process while retaining the CLI-shaped coordinator contract.
@MainActor
enum InProcessMachineCreateLauncher {
    typealias Invocation = CloudMachineCreateInvocation

    /// Recognizes the native subset without coupling the value model to the main actor.
    nonisolated static func parse(arguments: [String]) -> Invocation? {
        CloudMachineCreateArgumentParser().parse(arguments: arguments)
    }

    /// Namespaces the immutable coordinator identity for the create API.
    nonisolated static func idempotencyKey(operationID: UUID) -> String {
        CloudMachineCreateArgumentParser().idempotencyKey(operationID: operationID)
    }

    struct Dependencies {
        let create: @Sendable (Invocation, String) async throws -> VMSummary
        let record: @MainActor (VMSummary, VMCmuxRemoteEndpoint?) async -> CmuxTuiSurfaceProvider?
        let provider: @MainActor (String) -> CmuxTuiSurfaceProvider?
        let refresh: @MainActor () async -> Void
        let open: @MainActor (Invocation, CmuxTuiSurfaceProvider) async throws -> Void
        var validate: @MainActor (Invocation) throws -> Void = { _ in }
    }

    private static func dependencies(
        client: VMClient,
        registry: CmuxTuiSurfaceProviderRegistry,
        host: CloudWorkspaceCreationHost
    ) -> Dependencies {
        let scope = registry.creationScope
        return Dependencies(
            create: { invocation, key in
                try await client.create(
                    kind: invocation.kind,
                    persistentHome: false,
                    perMachineHome: false,
                    memoryMb: invocation.memoryMb,
                    displayName: invocation.displayName,
                    networkPolicy: invocation.networkPolicy,
                    agentUpdates: invocation.agentUpdates,
                    idempotencyKey: key
                )
            },
            record: { summary, attach in
                if let provider = await registry.recordCreatedMachine(summary, attach: attach, scope: scope) {
                    return provider
                }
                guard let scope, scope == registry.creationScope else { return nil }
                _ = await registry.refresh(force: false)
                return registry.provider(machineID: summary.id)
            },
            provider: { machineID in
                guard let scope, scope == registry.creationScope else { return nil }
                return registry.provider(machineID: machineID)
            },
            refresh: {
                guard let scope, scope == registry.creationScope else { return }
                _ = await registry.refresh(force: false)
            },
            open: { invocation, provider in
                try await open(
                    invocation, provider: provider, catalog: .shared, host: host,
                    refreshGraph: { await provider.refreshCurrentGraph(force: $0) },
                    validateScope: {
                        guard let scope, scope == registry.creationScope else {
                            throw CloudDiagnosticFailure.sessionRefresh
                        }
                    }
                )
            },
            validate: { invocation in
                guard let scope, scope == registry.creationScope else {
                    throw CloudDiagnosticFailure.sessionRefresh
                }
                try validateDestination(host: host)
                if invocation.machineID == nil {
                    guard hasUniqueLoadingPanel(workspaceID: invocation.workspaceID) else {
                        throw CloudDiagnosticFailure.placement
                    }
                }
            }
        )
    }

    private static func validateDestination(host: CloudWorkspaceCreationHost) throws {
        guard host.isAvailable, let manager = host.manager,
              let workspaceID = host.reservedWorkspaceID,
              let workspace = Workspace.liveWorkspace(id: workspaceID),
              workspace.owningTabManager === manager else {
            throw CloudDiagnosticFailure.placement
        }
    }

    private static func hasUniqueLoadingPanel(workspaceID: UUID) -> Bool {
        Workspace.liveWorkspace(id: workspaceID)?.panels.values.filter { $0 is CloudVMLoadingPanel }.count == 1
    }

    /// Admits manual input before graph discovery, retaining the initiating host
    /// and the shared coordinator's retry, cancellation, and placement ownership.
    static func open(
        _ invocation: Invocation,
        provider: any SurfaceProvider,
        catalog: SurfaceCatalog,
        host: CloudWorkspaceCreationHost,
        refreshGraph: @escaping @MainActor (Bool) async -> Bool,
        validateScope: @escaping @MainActor () throws -> Void
    ) async throws {
        let validateOperation: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try validateScope()
            try validateDestination(host: host)
            guard host.reservedWorkspaceID == invocation.workspaceID else {
                throw SurfaceCatalogError.destinationNotFound(invocation.workspaceID.uuidString)
            }
        }
        // Never recapture selection after an await or follow a moved destination
        // into a different window. An explicit retry captures its own host.
        try validateOperation()
        let boundRemoteWorkspaceID = Workspace.liveWorkspace(id: invocation.workspaceID)?.cloudVMBinding?.remoteWorkspaceID
        _ = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
            machine: provider.machine,
            provider: provider,
            catalog: catalog,
            name: invocation.displayName,
            focus: invocation.focus,
            host: host,
            resolveExistingWorkspace: {
                try validateOperation()
                if !(await refreshGraph(false)) {
                    try validateOperation()
                    guard await refreshGraph(true) else {
                        throw CloudDiagnosticFailure.sessionRefresh
                    }
                }
                try validateOperation()
                let machineInfo = catalog.snapshot.machines.first { $0.id == provider.machine }
                let remoteWorkspace: SurfaceRemoteWorkspace
                switch resolveRemoteWorkspace(in: machineInfo, boundID: boundRemoteWorkspaceID) {
                case .selected(let selected):
                    remoteWorkspace = selected
                case .empty:
                    return nil
                case .ambiguous, .unavailable:
                    throw SurfaceCatalogError.destinationNotFound("Cloud workspace selection")
                }
                switch resolveStarterTerminal(
                    in: catalog.snapshot.resources(on: provider.machine),
                    workspaceID: remoteWorkspace.id
                ) {
                case .selected(let terminal, let view):
                    return (remoteWorkspace, terminal, view)
                case .none:
                    return (remoteWorkspace, nil, nil)
                case .ambiguous:
                    throw SurfaceCatalogError.destinationNotFound("Cloud terminal selection")
                }
            },
            validateOperation: validateOperation,
            reuseFailedCreation: true
        )
    }

    private enum RemoteWorkspaceResolution {
        case selected(SurfaceRemoteWorkspace)
        case empty
        case ambiguous
        case unavailable
    }

    private enum StarterTerminalResolution {
        case selected(SurfaceResource, SurfaceRemoteView?)
        case none
        case ambiguous
    }

    /// Resolves the only safe remote workspace for a create/open operation.
    /// Bound identity wins; otherwise one focused row or one total row is required.
    private static func resolveRemoteWorkspace(
        in machineInfo: SurfaceMachineInfo?,
        boundID: String?
    ) -> RemoteWorkspaceResolution {
        guard let workspaces = machineInfo?.remoteWorkspaces else { return .unavailable }
        if let boundID, !boundID.isEmpty {
            let matches = workspaces.filter { $0.id == boundID }
            return matches.count == 1 ? .selected(matches[0]) : (matches.isEmpty ? .unavailable : .ambiguous)
        }
        if workspaces.isEmpty { return .empty }
        let focused = workspaces.filter(\.focused)
        if focused.count == 1 { return .selected(focused[0]) }
        if focused.count > 1 || workspaces.count > 1 { return .ambiguous }
        return .selected(workspaces[0])
    }

    /// Resolves a starter terminal without selecting by catalog array order.
    /// A focused matching view is authoritative; otherwise exactly one candidate is required.
    private static func resolveStarterTerminal(
        in resources: [SurfaceResource],
        workspaceID: String
    ) -> StarterTerminalResolution {
        var candidates: [(resource: SurfaceResource, view: SurfaceRemoteView?, focused: Bool)] = []
        var hasAmbiguousResource = false
        for resource in resources where resource.kind == .terminal && resource.lifecycle != .exited {
            if let views = resource.remoteViews {
                let matches = views.filter { $0.workspace.id == workspaceID }
                if matches.count == 1 {
                    candidates.append((resource, matches[0], matches[0].focused == true))
                } else if matches.count > 1 {
                    let focused = matches.filter { $0.focused == true }
                    if focused.count == 1 {
                        candidates.append((resource, focused[0], true))
                    } else {
                        hasAmbiguousResource = true
                    }
                }
            } else if resource.remoteWorkspace?.id == workspaceID {
                candidates.append((resource, nil, false))
            }
        }
        let focused = candidates.filter(\.focused)
        if focused.count == 1 { return .selected(focused[0].resource, focused[0].view) }
        if focused.count > 1 || candidates.count > 1 { return .ambiguous }
        if let candidate = candidates.first { return .selected(candidate.resource, candidate.view) }
        return hasAmbiguousResource ? .ambiguous : .none
    }

    static func run(
        _ invocation: Invocation,
        operationID: UUID,
        dependencies: Dependencies,
        onOutput: @escaping @MainActor (String) -> Void
    ) async -> CloudVMActionLauncher.Completion {
        var output = ""
        var machineID: String?
        var provider: CmuxTuiSurfaceProvider?
        do {
            try Task.checkCancellation()
            try dependencies.validate(invocation)
            if let openedMachineID = invocation.machineID {
                machineID = openedMachineID
            } else {
                let summary = try await dependencies.create(invocation, idempotencyKey(operationID: operationID))
                machineID = summary.id
                // A create may finish after the coordinator has tombstoned the
                // operation. Fence cancellation before admitting its receipt so
                // a late completion cannot repopulate another lifecycle.
                try Task.checkCancellation()
                let receipt = "OK machine=\(summary.id)\n"
                output += receipt
                onOutput(receipt)
                provider = await dependencies.record(summary, summary.createAttach)
            }
            guard let machineID else { throw VMClientError.malformedResponse("Cloud create did not name a machine.") }
            try Task.checkCancellation()
            if provider == nil {
                provider = dependencies.provider(machineID)
                if provider == nil {
                    await dependencies.refresh()
                    provider = dependencies.provider(machineID)
                }
            }
            guard let provider else {
                throw SurfaceCatalogError.noProvider(.cloud(machineID))
            }
            try await dependencies.open(invocation, provider)
            output += "workspace=\(invocation.workspaceID.uuidString)\n"
            return CloudVMActionLauncher.Completion(terminationStatus: 0, output: output, workspaceId: invocation.workspaceID, machineId: machineID)
        } catch is CancellationError {
            if Task.isCancelled {
                return CloudVMActionLauncher.Completion(
                    terminationStatus: 1, output: output, workspaceId: nil,
                    machineId: machineID, wasCancelled: true
                )
            }
            return CloudVMActionLauncher.Completion(
                terminationStatus: 1,
                output: output + CloudDiagnosticFailure.placement.label + "\n",
                workspaceId: nil,
                machineId: machineID
            )
        } catch {
            return CloudVMActionLauncher.Completion(
                terminationStatus: 1,
                output: output + CloudDiagnosticFailure.classify(error).label + "\n",
                workspaceId: nil,
                machineId: machineID
            )
        }
    }

    @discardableResult
    static func start(
        arguments: [String],
        operationID: UUID,
        onOutput: (@MainActor (String) -> Void)?,
        onCompletion: ((CloudVMActionLauncher.Completion) -> Void)?,
        onCancellationReady: ((CloudVMActionLauncher.CancellationHandle) -> Void)?
    ) -> Bool {
        guard let invocation = parse(arguments: arguments), let client = VMClient.shared,
              let workspace = Workspace.liveWorkspace(id: invocation.workspaceID),
              let manager = workspace.owningTabManager,
              !manager.isFinalizedForWindowClose else { return false }
        let registry = CmuxTuiSurfaceProviderRegistry.shared
        guard registry.creationScope != nil else { return false }
        let host = CloudWorkspaceCreationHost(manager: manager, reservedWorkspaceID: invocation.workspaceID)
        guard host.isAvailable else { return false }
        guard invocation.machineID != nil || hasUniqueLoadingPanel(workspaceID: invocation.workspaceID) else { return false }
        let deps = dependencies(client: client, registry: registry, host: host)
        let task = Task { @MainActor in
            let completion = await run(invocation, operationID: operationID, dependencies: deps, onOutput: { onOutput?($0) })
            onCompletion?(completion)
        }
        onCancellationReady?(CloudVMActionLauncher.CancellationHandle { task.cancel() })
        return true
    }
}
