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
    }

    private static func dependencies(
        client: VMClient,
        registry: CmuxTuiSurfaceProviderRegistry,
        host: CloudWorkspaceCreationHost?
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
                guard let scope, scope == registry.creationScope else {
                    throw CloudDiagnosticFailure.sessionRefresh
                }
                let catalog = SurfaceCatalog.shared
                await provider.refresh()
                guard scope == registry.creationScope else {
                    throw CloudDiagnosticFailure.sessionRefresh
                }
                guard let workspace = Workspace.liveWorkspace(id: invocation.workspaceID),
                      let manager = workspace.owningTabManager else {
                    throw SurfaceCatalogError.destinationNotFound(invocation.workspaceID.uuidString)
                }
                let machineInfo = catalog.snapshot.machines.first { $0.id == provider.machine }
                let boundRemoteWorkspaceID = workspace.cloudVMBinding?.remoteWorkspaceID
                let remoteWorkspace: SurfaceRemoteWorkspace?
                switch resolveRemoteWorkspace(in: machineInfo, boundID: boundRemoteWorkspaceID) {
                case .selected(let selected):
                    remoteWorkspace = selected
                case .empty:
                    remoteWorkspace = nil
                case .ambiguous, .unavailable:
                    throw SurfaceCatalogError.destinationNotFound("Cloud workspace selection")
                }
                let terminal: SurfaceResource?
                let remoteView: SurfaceRemoteView?
                if let remoteWorkspace {
                    switch resolveStarterTerminal(
                        in: catalog.snapshot.resources(on: provider.machine),
                        workspaceID: remoteWorkspace.id
                    ) {
                    case .selected(let selected, let selectedView):
                        terminal = selected
                        remoteView = selectedView
                    case .none:
                        terminal = nil
                        remoteView = nil
                    case .ambiguous:
                        throw SurfaceCatalogError.destinationNotFound("Cloud terminal selection")
                    }
                } else {
                    terminal = nil
                    remoteView = nil
                }
                guard let hostManager = host?.manager, hostManager === manager else {
                    throw SurfaceCatalogError.destinationNotFound(invocation.workspaceID.uuidString)
                }
                _ = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: provider.machine,
                    provider: provider,
                    catalog: catalog,
                    name: invocation.displayName,
                    focus: invocation.focus,
                    existingWorkspace: remoteWorkspace,
                    existingTerminal: terminal,
                    existingRemoteView: remoteView,
                    host: host,
                    validateOperation: { try Task.checkCancellation() }
                )
            }
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
        guard let invocation = parse(arguments: arguments), let client = VMClient.shared else { return false }
        let registry = CmuxTuiSurfaceProviderRegistry.shared
        guard registry.creationScope != nil else { return false }
        let host = Workspace.liveWorkspace(id: invocation.workspaceID).flatMap { workspace in
            workspace.owningTabManager.map {
                CloudWorkspaceCreationHost(manager: $0, reservedWorkspaceID: invocation.workspaceID)
            }
        }
        let deps = dependencies(client: client, registry: registry, host: host)
        let task = Task { @MainActor in
            let completion = await run(invocation, operationID: operationID, dependencies: deps, onOutput: { onOutput?($0) })
            onCompletion?(completion)
        }
        onCancellationReady?(CloudVMActionLauncher.CancellationHandle { task.cancel() })
        return true
    }
}
