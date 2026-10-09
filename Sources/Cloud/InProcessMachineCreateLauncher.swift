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

    private static func dependencies(client: VMClient, registry: CmuxTuiSurfaceProviderRegistry) -> Dependencies {
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
                guard scope == registry.creationScope else { return nil }
                _ = await registry.refresh(force: false)
                return registry.provider(machineID: summary.id)
            },
            provider: { machineID in registry.provider(machineID: machineID) },
            refresh: { _ = await registry.refresh(force: false) },
            open: { invocation, provider in
                let catalog = SurfaceCatalog.shared
                await provider.refresh()
                guard let workspace = Workspace.liveWorkspace(id: invocation.workspaceID),
                      let manager = workspace.owningTabManager else {
                    throw SurfaceCatalogError.destinationNotFound(invocation.workspaceID.uuidString)
                }
                let machineInfo = catalog.snapshot.machines.first { $0.id == provider.machine }
                let boundRemoteWorkspaceID = workspace.cloudVMBinding?.remoteWorkspaceID
                let remoteWorkspace = boundRemoteWorkspaceID.flatMap { id in
                    machineInfo?.remoteWorkspaces?.first { $0.id == id }
                } ?? machineInfo?.remoteWorkspaces?.first(where: \.focused)
                    ?? machineInfo?.remoteWorkspaces?.first
                let terminal = remoteWorkspace.flatMap { remote in
                    catalog.snapshot.resources(on: provider.machine).first {
                        $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == remote.id }
                    }
                }
                let remoteView = terminal.flatMap { resource in
                    remoteWorkspace.flatMap { workspace in
                        resource.remoteViews?.first { $0.workspace.id == workspace.id }
                    }
                }
                let host = CloudWorkspaceCreationHost(
                    manager: manager, reservedWorkspaceID: invocation.workspaceID
                )
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
            return CloudVMActionLauncher.Completion(terminationStatus: 1, output: output, workspaceId: nil, machineId: machineID, wasCancelled: true)
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
        let deps = dependencies(client: client, registry: registry)
        let task = Task { @MainActor in
            let completion = await run(invocation, operationID: operationID, dependencies: deps, onOutput: { onOutput?($0) })
            onCompletion?(completion)
        }
        onCancellationReady?(CloudVMActionLauncher.CancellationHandle { task.cancel() })
        return true
    }
}
