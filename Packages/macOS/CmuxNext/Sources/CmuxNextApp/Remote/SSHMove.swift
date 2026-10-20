import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextRemote
import Foundation

/// Move Chat to SSH Machine (cmuxterm-hq#2580 slice 1): a chat tab of this Mac moves to a
/// connected SSH machine, the way Move to Cloud (``CloudMove``) moves one to a Cloud machine.
/// Only the folder step differs: `cmux link stage ssh` puts the chat's git working copy in a
/// fresh worktree under the machine's `~/work` (uncommitted changes and untracked files
/// included), then the same `cmux link agent move` moves the chat there, asking first, and
/// the chat opens in a new workspace on the machine (``MovedChatTab``). This Mac's tab closes.
///
/// A preview (`labs.previewFeatures`). A stop is a toast with Retry. Once the folder is staged,
/// Retry moves the chat into that worktree without staging again, since a move that landed may
/// already have worked there (kept in memory only).
@MainActor
struct SSHMove {
    static let action: ActionID = "remote.moveChat"
    let services: AppServices

    /// The staged folder of each tab whose move stopped after the stage.
    private static var staged: [String: (machineID: String, cwd: String)] = [:]

    func start(_ invocation: ActionInvocation, context: AppActionContext) throws {
        guard !CloudMoveAsks.isAgent(invocation) else { throw ActionFailure(message: RemoteStrings.moveIsPersons) }
        guard let (tab, pane) = context.daemonTab(invocation) else { return }
        guard let record = tab.agentSession else { throw ActionFailure(message: RemoteStrings.moveNotAChat) }
        let tabs = services.agentTabs
        guard services.machines.daemon(forTab: tab).isLocal, record.host != tabs.chiefHost,
              !record.host.hasPrefix(MachineRegistry.registryHostPrefix) else {
            throw ActionFailure(message: CloudMoveStrings.alreadyRemote)
        }
        guard let session = tabs.sessions[tabs.resolve(tab.id)] ?? record.session else { throw ActionFailure(message: CloudMoveStrings.noSession) }
        guard let binary = services.cloud.move.cli else { throw ActionFailure(message: CloudStrings.noClient) }
        let machine = try self.machine(invocation)
        let cli = CloudMoveCLI(binary: binary, timeout: services.cloud.move.timeout)
        let name = machine.host.label, toastID = "ssh-move-" + tab.id, services = self.services
        CloudMove.toast(services, toastID, RemoteStrings.moveMoving(name), duration: .seconds(600))
        let work: ActionWork = Task { @MainActor in
            do {
                try await run(tab: tab, pane: pane, record: record, session: session, machine: machine, cli: cli, invocation: invocation)
                CloudMove.toast(services, toastID, CloudMoveStrings.moved(name), duration: .seconds(6))
                return nil
            } catch {
                let message = (error as? CloudMove.Failure)?.message ?? CloudMoveStrings.moveFailed(String(describing: error))
                services.cloud.logger.error("ssh move failed: \(message, privacy: .public)")
                var arguments = invocation.arguments
                arguments["machine"] = .string(machine.machineID)
                let again = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), arguments: arguments, origin: .user)
                let registry = services.registry
                CloudMove.toast(services, toastID, message, duration: .seconds(60), retry: { _ = registry.perform(Self.action, invocation: again) })
                return ActionWorkFailure(message)
            }
        }
        services.registry.track(work)
    }

    /// Stage, move, then open the chat on the machine and close this Mac's tab.
    private func run(tab: TabModel, pane: PaneModel, record: AgentSessionRef, session: String, machine: SSHMachineSession,
                     cli: CloudMoveCLI, invocation: ActionInvocation) async throws {
        let name = machine.host.label
        guard let machineSocket = await machine.daemon.connection?.endpoint?.socketPath,
              let localSocket = await services.daemon.connection?.endpoint?.socketPath else {
            throw CloudMove.Failure(message: CloudMoveStrings.notConnected(name))
        }
        let workspace = services.machines.local.store.workspace(containing: pane.handle)
        let cwd: String
        if let kept = Self.staged[tab.id], kept.machineID == machine.machineID {
            cwd = kept.cwd
        } else {
            guard let folder = try await CloudMove(services: services).chatFolder(tab: tab, workspace: workspace, session: session, invocation: invocation) else {
                throw CloudMove.Failure(message: CloudMoveStrings.noFolder)
            }
            let answer: CloudMoveCLI.Answer
            do {
                answer = try await cli.stageSSH(destination: machine.host.destination.sshArgument, port: machine.host.destination.port,
                                                key: session, folder: folder)
            } catch {
                throw CloudMove.Failure(message: CloudMoveStrings.syncFailed(name, String(describing: error)))
            }
            guard answer.ok, let staged = answer.cwd else {
                throw CloudMove.Failure(message: CloudMoveStrings.syncFailed(name, answer.error ?? answer.errorCode ?? ""))
            }
            Self.staged[tab.id] = (machine.machineID, staged)
            cwd = staged
        }
        let moved: CloudMoveCLI.Answer
        do {
            // An SSH machine guards a moved chat like a web start: it asks before it acts there.
            moved = try await cli.agentMove(from: localSocket, surface: tab.surface.rawValue, to: machineSocket, cwd: cwd, askFirst: true)
        } catch {
            // Timed out or didn't run to its answer: the move may have committed, and a rerun resolves it.
            throw CloudMove.Failure(message: CloudMoveStrings.unresolved)
        }
        guard moved.ok, let movedSession = moved.sessionID else {
            throw CloudMove.failure(moving: moved, machine: name, retry: .move(machineID: machine.machineID))
        }
        Self.staged[tab.id] = nil
        do {
            try await MovedChatTab.open(movedSession, harness: record.harness, on: machine.daemon, hostName: name, repair: machine.emptyWorkspaces,
                                        in: cwd, name: workspace?.name, mutationID: "ssh-move-" + (moved.transferID ?? movedSession), services: services)
        } catch {
            throw CloudMove.Failure(message: CloudMoveStrings.tabFailed(name, String(describing: error)))
        }
        do {
            try await services.daemon.connection?.closeTabs([tab.surface], endTerminals: false, reason: .sessionEnd)
        } catch {
            services.cloud.logger.error("ssh move: closing the moved tab failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The `machine` argument's SSH machine, else the first connected one; connected either way.
    private func machine(_ invocation: ActionInvocation) throws -> SSHMachineSession {
        let machines = services.machines
        let ready = { (session: SSHMachineSession) in
            session.daemon.connection != nil && AgentTabStore.registryHost(of: session.daemon) != nil
        }
        guard let named = invocation["machine"]?.targetValue?.id ?? invocation["machine"]?.stringValue else {
            guard let session = machines.ssh.first(where: ready) else { throw ActionFailure(message: RemoteStrings.moveNoMachine) }
            return session
        }
        let id = named.hasPrefix("machine:") ? String(named.dropFirst("machine:".count)) : named
        guard let session = machines.sshSession(id) else { throw ActionFailure(message: RemoteStrings.moveNoMachine) }
        guard ready(session) else { throw ActionFailure(message: CloudMoveStrings.notConnected(session.host.label)) }
        return session
    }
}
