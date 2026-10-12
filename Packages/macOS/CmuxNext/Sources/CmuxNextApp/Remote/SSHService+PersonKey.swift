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

    private static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").last.map(String.init)
    }
}
