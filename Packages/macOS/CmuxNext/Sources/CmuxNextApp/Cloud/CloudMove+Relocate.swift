import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// Move to another Cloud machine (a Cloud chat's Move to…): one `cmux link agent move --sync relay`
/// copies the folder machine to machine through this Mac's two links (nothing lands here), freezes
/// the chat only for what changed since, and moves it; its toasts, card and Retry are the move's.
@MainActor
extension CloudMove {
    /// The Cloud machine a chat runs on, by its record's `registry:` host.
    static func runningMachine(_ record: AgentSessionRef?, _ services: AppServices) -> CloudMachineSession? {
        guard let record, record.host.hasPrefix(MachineRegistry.registryHostPrefix) else { return nil }
        return services.machines.cloud.first { AgentTabStore.registryHost(of: $0.daemon) == record.host }
    }

    /// Starts moving a Cloud chat to the machine `invocation` names; false when this is not such a move.
    func startRelocate(_ invocation: ActionInvocation, context: AppActionContext) throws -> Bool {
        guard let (tab, _) = context.daemonTab(invocation), let record = tab.agentSession, invocation["machine"] != nil,
              let source = Self.runningMachine(record, services) else { return false }
        if case .show = services.cloud.moveRetries[tab.id] { return false } // committed: Retry only opens it
        guard let session = Self.session(tab, services) else { throw ActionFailure(message: CloudMoveStrings.noSession) }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        perform(tab: tab, invocation: invocation) { try await relocate(tab: tab, record: record, session: session, from: source, cli: cli, invocation: invocation) }
        return true
    }

    private func relocate(tab: TabModel, record: AgentSessionRef, session: String, from source: CloudMachineSession, cli: CloudMoveCLI,
                          invocation: ActionInvocation) async throws -> String {
        let target = try await machine(invocation) { nil }
        guard target.machineID != source.machineID else { throw Failure(message: CloudMoveStrings.alreadyRemote) }
        let from = try await Self.connected(source, invocation), name = target.machine.title, again = CloudMoveRetries.Retry.move(machineID: target.machineID)
        guard let fromSocket = await from.daemon.connection?.endpoint?.socketPath, let toSocket = await target.daemon.connection?.endpoint?.socketPath,
              let toHost = AgentTabStore.registryHost(of: target.daemon) else { throw Failure(message: CloudMoveStrings.notConnected(name), retry: again) }
        let entry = services.cloud.movedChats.entry(host: record.host, session: session)
        guard let folder = CloudMoveTargetRules().folder(remoteFolder: entry?.remoteFolder, remoteChat: entry?.remoteChat, cwd: tab.cwd) else {
            throw Failure(message: CloudMoveStrings.noFolder)
        }
        services.cloud.moveRetries[tab.id] = again
        let owner = await Self.ownerAnswer(target), moved: CloudMoveCLI.Answer
        do {
            let sync = CloudMoveCLI.FrozenSync(pull: false, socket: toSocket, local: folder.root, remote: folder.root, fromSocket: fromSocket, seedLocal: entry?.localRoot)
            moved = try await cli.agentMove(from: fromSocket, surface: tab.surface.rawValue, to: toSocket, cwd: folder.chat, sync: sync,
                                            vmKind: owner.vmKind, toPID: owner.toPID)
        } catch {
            services.cloud.logger.error("cloud relocate: link agent move: \(String(describing: error), privacy: .public)")
            throw Failure(message: CloudMoveStrings.unresolved, retry: again)
        }
        guard moved.ok, let movedSession = moved.sessionID else { throw CloudMoveFailure.moving(moved, machine: name, retry: again) }
        services.cloud.movedChats.follow(host: record.host, session: session, toMachine: target.machineID, host: toHost, session: movedSession)
        let shown = CloudMoveRetries.Shown(session: movedSession, harness: record.harness, machineID: target.machineID, folder: folder.chat,
                                           name: nil, key: moved.transferID ?? movedSession)
        services.cloud.moveRetries[tab.id] = .show(shown)
        try await finish(shown, on: target, tab: tab)
        return name
    }
}
