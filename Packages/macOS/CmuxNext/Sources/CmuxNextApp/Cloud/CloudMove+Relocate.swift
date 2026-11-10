import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import Foundation

/// Move to another Cloud machine: ``CloudMove``'s run for a chat that already runs on a Cloud
/// machine, named to move to another one (the composer's and the title menu's Move to…). Wiring
/// only: the copy and the move are one CLI run (`cmux link agent move --sync relay`, whose argv
/// `cmux-cloud-start-core` builds), pumped through this Mac between the two machines' links, and
/// nothing of the folder lands on this Mac's disk. The chat freezes on the first machine only for
/// the move itself: the CLI copies the bulk before, and its frozen pass sends what changed since. A failure before the commit gives the chat back where it was (the CLI's abort); a
/// committed move opens the chat on the new machine, closes its old tab, and moves its Bring Back
/// Local record along, so the chat still comes back to the folder on this Mac it left.
@MainActor
extension CloudMove {
    /// The Cloud machine a chat tab runs on, from its record's `registry:` host.
    static func runningMachine(_ record: AgentSessionRef?, _ services: AppServices) -> CloudMachineSession? {
        guard let record, record.host.hasPrefix(MachineRegistry.registryHostPrefix) else { return nil }
        return services.machines.cloud.first { AgentTabStore.registryHost(of: $0.daemon) == record.host }
    }

    /// Starts moving a Cloud machine's chat to the machine `invocation` names, or answers false
    /// when this is not such a move (a chat of this Mac: the plain Move to Cloud).
    func startRelocate(_ invocation: ActionInvocation, context: AppActionContext) throws -> Bool {
        guard let (tab, _) = context.daemonTab(invocation), let record = tab.agentSession,
              let source = Self.runningMachine(record, services) else { return false }
        let named = invocation["machine"]?.targetValue?.id ?? invocation["machine"]?.stringValue
        guard let named else { throw ActionFailure(message: CloudMoveStrings.alreadyRemote) }
        let targetID = named.hasPrefix("machine:") ? String(named.dropFirst("machine:".count)) : named
        guard targetID != source.machineID else { throw ActionFailure(message: CloudMoveStrings.alreadyRemote) }
        guard let target = services.machines.session(targetID) else { throw ActionFailure(message: CloudMoveStrings.noSuchMachine(targetID)) }
        guard let session = record.session ?? services.agentTabs.sessions[services.agentTabs.tabKey(of: tab)] else {
            throw ActionFailure(message: CloudMoveStrings.noSession)
        }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        let toastID = "cloud-move-" + tab.id
        toast(toastID, CloudMoveStrings.moving, duration: Self.working)
        let work: ActionWork = Task { @MainActor in
            do {
                let name = try await relocate(tab: tab, record: record, session: session, from: source, to: target, cli: cli, invocation: invocation)
                toast(toastID, CloudMoveStrings.moved(name), duration: .seconds(6))
                return nil
            } catch {
                let message = (error as? Failure)?.message ?? (error as? ActionFailure)?.message ?? CloudMoveStrings.moveFailed(CloudStrings.errorText(error))
                services.cloud.logger.error("cloud relocate failed: \(message, privacy: .public)")
                toast(toastID, message, duration: .seconds(12))
                return ActionWorkFailure(message)
            }
        }
        services.registry.track(work)
        return true
    }

    private func relocate(tab: TabModel, record: AgentSessionRef, session: String, from source: CloudMachineSession, to target: CloudMachineSession,
                          cli: CloudMoveCLI, invocation: ActionInvocation) async throws -> String {
        let from = try await Self.connected(source, invocation)
        let to = try await Self.connected(target, invocation)
        let name = to.machine.title
        guard let fromSocket = await from.daemon.connection?.endpoint?.socketPath,
              let toSocket = await to.daemon.connection?.endpoint?.socketPath,
              let toHost = AgentTabStore.registryHost(of: to.daemon) else { throw Failure(message: CloudMoveStrings.notConnected(name)) }
        // The folder that goes: the one a move from this Mac put there (its root, so a chat in a
        // subfolder keeps its repository), else the chat's own. Both machines keep it at the same path.
        let entry = services.cloud.movedChats.entry(host: record.host, session: session)
        guard let chat = entry?.remoteChat ?? tab.cwd, chat.hasPrefix("/") else { throw Failure(message: CloudMoveStrings.noFolder) }
        let root = entry?.remoteFolder ?? chat
        let owner = await Self.ownerAnswer(to)
        let sync = CloudMoveCLI.FrozenSync(pull: false, socket: toSocket, local: root, remote: root, fromSocket: fromSocket)
        let moved: CloudMoveCLI.Answer
        do {
            moved = try await cli.agentMove(from: fromSocket, surface: tab.surface.rawValue, to: toSocket, cwd: chat, sync: sync,
                                            vmKind: owner.vmKind, toPID: owner.toPID)
        } catch {
            services.cloud.logger.error("cloud relocate: link agent move: \(String(describing: error), privacy: .public)")
            throw Failure(message: CloudMoveStrings.unresolved)
        }
        guard moved.ok, let movedSession = moved.sessionID else { throw Self.failure(moving: moved, machine: name, retry: .move(machineID: to.machineID)) }
        // Bring Back Local follows the chat to its new machine, back into the same folder here.
        if var entry {
            services.cloud.movedChats.forget(host: record.host, session: session)
            (entry.machineID, entry.host, entry.session) = (to.machineID, toHost, movedSession)
            services.cloud.movedChats.record(entry)
        }
        let shown = CloudMoveRetries.Shown(session: movedSession, harness: record.harness, machineID: to.machineID, folder: chat,
                                           name: nil, key: moved.transferID ?? movedSession)
        try await show(shown.session, harness: shown.harness, on: to, in: shown.folder, name: shown.name, key: shown.key)
        do {
            try await from.daemon.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
        } catch {
            services.cloud.logger.error("cloud relocate: closing the moved tab failed: \(String(describing: error), privacy: .public)")
        }
        return name
    }
}
