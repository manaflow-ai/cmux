import AppKit
import CmuxCloud
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
import Foundation

/// Launches the New Machine flow in-process while retaining the CLI-shaped coordinator contract.
@MainActor
enum InProcessMachineCreateLauncher {
    struct Invocation: Equatable, Sendable {
        let machineID: String?
        let kind: VMMachineKind?
        let memoryMb: Int?
        let displayName: String?
        let networkPolicy: CloudNetworkPolicy?
        let agentUpdates: CloudAgentUpdates?
        let workspaceID: UUID
        let focus: Bool
        let windowID: UUID?
    }

    nonisolated static let placeholderCommand = "sleep 60"

    /// Recognizes only the New Machine subset. Base, fork, image overrides, and unknown flags stay on CLI.
    nonisolated static func parse(arguments: [String]) -> Invocation? {
        guard arguments.count >= 2, arguments[0] == "vm" else { return nil }
        let verb = arguments[1]
        guard verb == "new" || verb == "open" else { return nil }
        if verb == "open" {
            guard arguments.count >= 3, !arguments[2].isEmpty, !arguments[2].hasPrefix("-") else { return nil }
            var focus = true
            var workspaceID: UUID?
            var windowID: UUID?
            var index = 3
            while index < arguments.count {
                switch arguments[index] {
                case "--focus":
                    guard index + 1 < arguments.count else { return nil }
                    switch arguments[index + 1].lowercased() {
                    case "true", "1", "yes": focus = true
                    case "false", "0", "no": focus = false
                    default: return nil
                    }
                    index += 1
                case "--workspace":
                    guard index + 1 < arguments.count, let value = UUID(uuidString: arguments[index + 1]) else { return nil }
                    workspaceID = value; index += 1
                case "--window":
                    guard index + 1 < arguments.count, let value = UUID(uuidString: arguments[index + 1]) else { return nil }
                    windowID = value; index += 1
                default: return nil
                }
                index += 1
            }
            guard let workspaceID else { return nil }
            return Invocation(
                machineID: arguments[2], kind: nil, memoryMb: nil, displayName: nil,
                networkPolicy: nil, agentUpdates: nil, workspaceID: workspaceID,
                focus: focus, windowID: windowID
            )
        }
        var kind: VMMachineKind?
        var memoryMb: Int?
        var displayName: String?
        var networkPolicy: CloudNetworkPolicy?
        var agentUpdates: CloudAgentUpdates?
        var focus = true
        var workspaceID: UUID?
        var windowID: UUID?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--desktop": kind = .desktop
            case "--base", "--no-desktop": return nil
            case "--size":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else { return nil }
                memoryMb = value; index += 1
            case "--name":
                guard index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                displayName = value.isEmpty ? nil : value; index += 1
            case "--network-policy":
                guard index + 1 < arguments.count,
                      let data = arguments[index + 1].data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let policy = try? CloudNetworkPolicy(foundationObject: object) else { return nil }
                networkPolicy = policy; index += 1
            case "--agent-updates":
                guard index + 1 < arguments.count, let value = CloudAgentUpdates(rawValue: arguments[index + 1]) else { return nil }
                agentUpdates = value; index += 1
            case "--focus":
                guard index + 1 < arguments.count else { return nil }
                switch arguments[index + 1].lowercased() {
                case "true", "1", "yes": focus = true
                case "false", "0", "no": focus = false
                default: return nil
                }
                index += 1
            case "--workspace":
                guard index + 1 < arguments.count, let value = UUID(uuidString: arguments[index + 1]) else { return nil }
                workspaceID = value; index += 1
            case "--window":
                guard index + 1 < arguments.count, let value = UUID(uuidString: arguments[index + 1]) else { return nil }
                windowID = value; index += 1
            default: return nil
            }
            index += 1
        }
        guard let workspaceID else { return nil }
        return Invocation(
            machineID: nil, kind: kind, memoryMb: memoryMb, displayName: displayName,
            networkPolicy: networkPolicy, agentUpdates: agentUpdates,
            workspaceID: workspaceID, focus: focus, windowID: windowID
        )
    }

    nonisolated static func idempotencyKey(operationID: UUID) -> String {
        "app-" + operationID.uuidString.lowercased()
    }

    struct Dependencies {
        let create: @Sendable (Invocation, String) async throws -> VMSummary
        let status: @Sendable (String) async throws -> VMSummary
        let record: @MainActor (VMSummary, VMCmuxRemoteEndpoint?) async -> Void
        let prepare: @MainActor (UUID) throws -> Void
        let bind: @MainActor (UUID, String) -> Void
        let connect: @MainActor (String) async throws -> Void
        let terminal: @MainActor (String, UUID, Bool) async throws -> String?
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
            status: { id in try await client.status(id: id) },
            record: { summary, attach in await registry.recordCreatedMachine(summary, attach: attach, scope: scope) },
            prepare: { workspaceID in
                guard let workspace = Workspace.liveWorkspace(id: workspaceID),
                      workspace.panels.values.contains(where: { $0.panelType == .cloudVMLoading }) else {
                    throw CloudMachineLinkManager.ManagerError.retryLater("The reserved Cloud workspace is no longer available.")
                }
                (workspace.panels.values.first { $0.panelType == .cloudVMLoading } as? CloudVMLoadingPanel)?.resetLoading()
            },
            bind: { workspaceID, machineID in
                SurfaceCatalog.shared.bindCloudWorkspace(
                    localWorkspaceID: workspaceID,
                    machine: .cloud(machineID),
                    remoteWorkspaceID: nil,
                    isBase: false,
                    generatedTitle: String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM")
                )
            },
            connect: { machineID in _ = try await registry.linkSocketPath(machineID: machineID) },
            terminal: { machineID, workspaceID, focus in
                let payload = try await TerminalController.surfaceNewTerminal(
                    machine: .cloud(machineID), command: nil, cwd: nil, name: nil,
                    remoteWorkspaceID: nil,
                    destination: .workspace(id: workspaceID, placement: .tab),
                    focus: focus
                )
                return payload["remote_workspace_id"] as? String
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
        do {
            if let openedMachineID = invocation.machineID {
                machineID = openedMachineID
            } else {
                var summary = try await dependencies.create(invocation, idempotencyKey(operationID: operationID))
                machineID = summary.id
                let receipt = "OK machine=\(summary.id)\n"
                output += receipt
                onOutput(receipt)
                if summary.createAttach?.networkAddresses?.ipv4 != nil || summary.createAttach?.networkAddresses?.ipv6 != nil {
                    if summary.addressIPv4 == nil { summary.addressIPv4 = summary.createAttach?.networkAddresses?.ipv4 }
                    if summary.addressIPv6 == nil { summary.addressIPv6 = summary.createAttach?.networkAddresses?.ipv6 }
                }
                await dependencies.record(summary, summary.createAttach)
            }
            guard let machineID else { throw VMClientError.malformedResponse("Cloud create did not name a machine.") }
            try Task.checkCancellation()
            try dependencies.prepare(invocation.workspaceID)
            dependencies.bind(invocation.workspaceID, machineID)
            try await dependencies.connect(machineID)
            try Task.checkCancellation()
            let remoteWorkspaceID = try await dependencies.terminal(machineID, invocation.workspaceID, invocation.focus)
            if let remoteWorkspaceID, !remoteWorkspaceID.isEmpty {
                SurfaceCatalog.shared.bindCloudWorkspace(
                    localWorkspaceID: invocation.workspaceID,
                    machine: .cloud(machineID),
                    remoteWorkspaceID: remoteWorkspaceID,
                    isBase: false,
                    generatedTitle: String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM")
                )
            }
            output += "workspace=\(invocation.workspaceID.uuidString)\n"
            return CloudVMActionLauncher.Completion(terminationStatus: 0, output: output, workspaceId: invocation.workspaceID, machineId: machineID)
        } catch is CancellationError {
            return CloudVMActionLauncher.Completion(terminationStatus: 1, output: output, workspaceId: nil, machineId: machineID, wasCancelled: true)
        } catch {
            return CloudVMActionLauncher.Completion(
                terminationStatus: 1,
                output: output + "\(error)\n",
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
