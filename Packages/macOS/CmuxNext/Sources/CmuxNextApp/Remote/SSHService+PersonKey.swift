import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextRemote
import Foundation

/// cx-0q7o slice 2c (D2, D3): remote approvals for an SSH machine (and a paired server on the
/// `ssh` route). The app restarts the machine's acpmux with a new person key of its own, over its
/// own ssh exec, and then checks over a fresh nonce that the new daemon run holds that key
/// (`_acpmux/person_holds`). Only then does the pane sign relayed allows for that run. The key
/// goes only to the stdin of `acp daemon start --person-key-fd 0` (never argv, env, a file or a
/// log); the remote cmux-tui session daemon never holds it.
extension SSHService {
    /// Restarts `session`'s acpmux with a new key; nil on success, else what failed.
    func restartWithApprovals(_ session: SSHMachineSession) async -> AgentPaneRemoteApprovals.Failure? {
        let host = session.host, machine = session.machineID
        let environment = await Self.environment()
        AcpmuxRemotePersonKeys.shared.drop(machine: machine)
        guard let key = AcpmuxSecretKey() else { return .noRandomness }
        let commandLine = SSHCommandLine()
        let binary = host.remoteBinary
        do {
            // A running daemon holds another key or none: hand its agents off and stop it first
            // (durable agents survive; the new run adopts them, and their prompts get new nonces).
            _ = try await SSHProcessRunner.run(commandLine.command(host, "\(binary) acp daemon shutdown --keep-agents </dev/null"),
                                               environment: environment, deadline: .seconds(60),
                                               label: "acpmux shutdown \(host.destination)")
            let started = try await SSHProcessRunner.run(
                commandLine.command(host, "\(binary) acp --json daemon start --person-key-fd 0"),
                input: .writer { descriptor in key.writeLine(to: descriptor) }, environment: environment,
                deadline: .seconds(60), label: "acpmux keyed start \(host.destination)")
            let status = (try? JSONSerialization.blockingJSONObject(with: Data(started.stdout.utf8))) as? [String: Any]
            guard started.status == 0, status?["personKey"] as? Bool == true,
                  let instance = status?["personInstance"] as? String else {
                return .daemonTookNoKey(Self.lastLine(started.stderr))
            }
            // The answer only a run that holds this key can give; whatever else answers on the
            // socket path cannot (a `person_prove` reply alone would prove nothing). A dropped ssh
            // call is asked once more, with a new nonce (cx-hd3rw): else the new run would hold a key
            // this app never bound.
            var proved = false
            for attempt in 1...2 where !proved {
                guard let nonce = AcpmuxSecretKey.newNonce() else { return .noRandomness }
                let (reply, error) = await host.personHolds(nonce: nonce, environment: environment)
                if Task.isCancelled { return .failed("cancelled") }
                // No answer at all: the call itself failed; ask again once.
                guard let reply else { if attempt == 2 { return .failed(error) }; continue }
                guard let proof = reply.proof, reply.instance == instance,
                      key.holds(proof: proof, instance: instance, nonce: nonce) else { return .keyNotHeld }
                proved = true
            }
            AcpmuxRemotePersonKeys.shared.bind(machine: machine, instance: instance, key: key)
            logger.info("remote approvals on for \(host.destination.description, privacy: .public)")
            return nil
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// cx-oa6ah: the keyed restart before a new chat starts on `session`, only when nothing on
    /// that machine's acpmux can be lost: none runs, or it is ready, keeps agent hosts across a
    /// restart, and runs no live agent and no proxied peer session. That machine's cmux-tui
    /// decides it (`.daemonSaidSafe`, cx-0w0jj); for an older cmux-tui the app reads the status
    /// itself (`.checkStatus`), and anything else (live agents, an ssh error, a reply it cannot
    /// read) leaves the daemon as it is (fail closed). Its Allow then shows the restart notice,
    /// and only the person's click restarts it. One preparation per machine at a time. True once
    /// this app's key is bound to the daemon that will run the chat.
    func restartWithApprovalsIfIdle(_ session: SSHMachineSession, _ preparation: AgentPaneRemoteApprovals.Preparation) async -> Bool {
        logger.info("keyed restart before a chat on \(session.host.destination.description, privacy: .public): \(String(describing: preparation), privacy: .public)")
        switch preparation {
        case .daemonSaidSafe:
            return await RemoteApprovalPreparations.shared.run(machine: session.machineID, keepBusy: false) { [self] in
                await restartWithApprovals(session) == nil
            }
        case .checkStatus:
            if AcpmuxRemotePersonKeys.shared.instance(machine: session.machineID) != nil { return true }
            return await RemoteApprovalPreparations.shared.run(machine: session.machineID, keepBusy: true) { [self] in
                guard await idleAgentDaemon(session) else { return false }
                return await restartWithApprovals(session) == nil
            }
        }
    }

    /// cx-brq9m: after an install the keyed restart hands the acpmux over to the new binary when
    /// nothing is lost (``RemoteAgentDaemonStatus/handoffBlocker``); true when the new one runs.
    @discardableResult
    func handOffAgentDaemonAfterInstall(_ session: SSHMachineSession) async -> Bool {
        let name = session.host.destination.description
        guard let status = await RemoteAgentDaemonStatus.read(session.host, environment: await Self.environment()) else {
            logger.info("agent daemon on \(name, privacy: .public) left as it is after the install: status unreadable")
            return false
        }
        if !status.running { return true }
        if let blocker = status.handoffBlocker {
            logger.info("agent daemon on \(name, privacy: .public) left as it is after the install: \(blocker, privacy: .public)")
            return false
        }
        let handed = await RemoteApprovalPreparations.shared.run(machine: session.machineID, keepBusy: false) { [self] in
            await restartWithApprovals(session) == nil
        }
        logger.info("agent daemon on \(name, privacy: .public) handed over after the install: \(handed, privacy: .public)")
        return handed
    }

    /// cx-3r9mt: whether an automatic update may run (``RemoteAgentDaemonStatus/idleForUpdate(ownInstance:)``).
    func agentDaemonIdleForUpdate(_ session: SSHMachineSession) async -> Bool {
        let ours = AcpmuxRemotePersonKeys.shared.instance(machine: session.machineID)
        return await RemoteAgentDaemonStatus.read(session.host, environment: await Self.environment())?.idleForUpdate(ownInstance: ours) == true
    }

    /// The fallback for a cmux-tui without `agent-session-start-keyed-reason-v1` (remove with
    /// `.checkStatus`; see ``restartWithApprovalsIfIdle``).
    private func idleAgentDaemon(_ session: SSHMachineSession) async -> Bool {
        await RemoteAgentDaemonStatus.read(session.host, environment: await Self.environment())?.idleForKeyedRestart == true
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").last.map(String.init)
    }
}
