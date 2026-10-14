import CmuxNextAgentPane
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
            let status = (try? JSONSerialization.jsonObject(with: Data(started.stdout.utf8))) as? [String: Any]
            guard started.status == 0, status?["personKey"] as? Bool == true,
                  let instance = status?["personInstance"] as? String else {
                return .daemonTookNoKey(Self.lastLine(started.stderr))
            }
            guard let nonce = AcpmuxSecretKey.newNonce() else { return .noRandomness }
            // The answer only a run that holds this key can give; whatever else answers on the
            // socket path cannot (a `person_prove` reply alone would prove nothing).
            let frames = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"# + "\n"
                + #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/person_holds","params":{"nonce":""# + nonce + #""}}"# + "\n"
            let held = try await SSHProcessRunner.run(commandLine.command(host, "\(binary) acp stdio"),
                                                      input: .data(Data(frames.utf8)), environment: environment,
                                                      deadline: .seconds(30), label: "acpmux person_holds \(host.destination)")
            let answer = held.stdout.split(separator: "\n").lazy
                .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                .first { ($0["id"] as? Int) == 2 }
            let result = answer?["result"] as? [String: Any]
            guard let proof = result?["proof"] as? String, result?["instance"] as? String == instance,
                  key.holds(proof: proof, instance: instance, nonce: nonce) else {
                return .keyNotHeld
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

    /// The fallback for a cmux-tui without `agent-session-start-keyed-reason-v1` (remove with
    /// `.checkStatus`; the rule lives in cmux-tui's `keyed_restart_reason`): true only for an
    /// answer that shows nothing to lose (see ``restartWithApprovalsIfIdle``).
    private func idleAgentDaemon(_ session: SSHMachineSession) async -> Bool {
        guard let status = try? await SSHProcessRunner.run(
            SSHCommandLine().command(session.host, "\(session.host.remoteBinary) acp --json daemon status </dev/null"),
            environment: await Self.environment(), deadline: .seconds(10), label: "acpmux status \(session.host.destination)"),
            status.status == 0,
            let object = (try? JSONSerialization.jsonObject(with: Data(status.stdout.utf8))) as? [String: Any] else { return false }
        if object["running"] as? Bool == false { return true }
        return object["ready"] as? Bool == true && object["agentHosts"] as? Bool == true
            && object["liveAgents"] as? Int == 0 && object["remoteSessions"] as? Int == 0
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").last.map(String.init)
    }
}

/// One keyed-restart preparation per machine at a time (two tabs starting at once share it), and
/// (`keepBusy`, the app's own status check) a busy answer kept for a minute so a busy machine
/// costs one status call per minute. The daemon's answer comes with each start, so it keeps none.
actor RemoteApprovalPreparations {
    static let shared = RemoteApprovalPreparations()
    private var running: [String: Task<Bool, Never>] = [:]
    private var busyUntil: [String: ContinuousClock.Instant] = [:]

    func run(machine: String, keepBusy: Bool, _ work: @escaping @Sendable () async -> Bool) async -> Bool {
        if keepBusy, let until = busyUntil[machine], ContinuousClock.now < until { return false }
        if let task = running[machine] { return await task.value }
        // task-owner: the machine's one preparation; every caller awaits it
        let task = Task { await work() }
        running[machine] = task
        let bound = await task.value
        running[machine] = nil
        if keepBusy || bound { busyUntil[machine] = bound ? nil : ContinuousClock.now.advanced(by: .seconds(60)) }
        return bound
    }
}
