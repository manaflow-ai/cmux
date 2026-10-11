import CmuxNextAgentPane
import CmuxNextCloud
import Foundation

/// cx-0q7o slice 2d (cx-psxg): remote approvals for a Cloud machine on the `/api/vm` link. The app
/// restarts the machine's acpmux with a new person key of its own through the Cloud service
/// (`POST /api/vm/{id}/acpmux/keyed-start`), then checks over a fresh nonce of its own that the
/// new daemon run holds that key (`person-holds`). Only then does the pane sign relayed allows for
/// that run. The key goes only into that one request's body stream (never argv, env, a file, a
/// log or a retry); the Cloud service gives it to the machine only as the stdin of
/// `acp daemon start --person-key-fd 0` and keeps no copy (#13742 D16 update 4: the service and the
/// VM provider are trusted for key delivery).
extension CloudService {
    /// Restarts `session`'s acpmux with a new key; nil on success, else what failed.
    func restartWithApprovals(_ session: CloudMachineSession) async -> AgentPaneRemoteApprovals.Failure? {
        let machine = session.machineID
        AcpmuxRemotePersonKeys.shared.drop(machine: machine)
        guard let key = AcpmuxSecretKey() else { return .noRandomness }
        do {
            let instance = try await api.acpmuxKeyedStart(machine, keyLineLength: AcpmuxSecretKey.lineLength) { key.writeLine(to: $0) }
            guard let nonce = AcpmuxSecretKey.newNonce() else { return .noRandomness }
            // The answer only a run that holds this key can give; the service relays it and
            // cannot make it.
            let held = try await api.acpmuxPersonHolds(machine, nonce: nonce)
            guard held.instance == instance, key.holds(proof: held.proof, instance: instance, nonce: nonce) else {
                return .keyNotHeld
            }
            AcpmuxRemotePersonKeys.shared.bind(machine: machine, instance: instance, key: key)
            logger.info("remote approvals on for Cloud machine \(machine, privacy: .public)")
            return nil
        } catch let error as CloudAPIError {
            return Self.approvalsFailure(error)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The pane's reason for a refused or failed keyed start (the route's `vm_acpmux_*` codes).
    nonisolated static func approvalsFailure(_ error: CloudAPIError) -> AgentPaneRemoteApprovals.Failure {
        guard case let .http(_, code, message) = error else { return .failed(error.description) }
        switch code {
        case "vm_acpmux_unsupported": return .daemonTooOld
        case "vm_acpmux_not_running": return .machineNotRunning
        case "vm_acpmux_not_single_owner", "vm_acpmux_team_vm": return .notSingleOwner
        case "vm_acpmux_start_failed": return .daemonTookNoKey(nil)
        case "vm_acpmux_holds_failed": return .keyNotHeld
        default: return .failed(message ?? error.description)
        }
    }
}
