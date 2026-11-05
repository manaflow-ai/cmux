import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextRemote
import Foundation

/// cx-0q7o slices 2d (cx-psxg) and 2e (cx-kvmz): remote approvals for a Cloud machine. The app
/// restarts the machine's acpmux with a new person key of its own through the Cloud service, then
/// checks over a fresh nonce of its own that the new daemon run holds that key (`person-holds`).
/// Only then does the pane sign relayed allows for that run. The key goes only into that one
/// request's body stream (never argv, env, a file, a log or a retry); the Cloud service gives it
/// to the machine only as the stdin of `acp daemon start --person-key-fd 0` and keeps no copy
/// (#13742 D16 update 4: the service and the VM provider are trusted for key delivery).
///
/// Two routes, one verifier: a machine on the `/api/vm` link uses the web Cloud service
/// (`/api/vm/{id}/acpmux/...`); a machine on the Cloud app server link uses the cmux-next API
/// Worker directly with the person's session (`/v1/cloud/machines/{machine}/acpmux/...`), never
/// `apps-run`, the local daemon or a Cloud op.
extension CloudService {
    /// The keyed start and the person_holds check of one route.
    struct ApprovalsRoute {
        let keyedStart: (_ machine: String, _ keyLineLength: Int, _ writeKey: (OutputStream) -> Bool) async throws -> String
        let personHolds: (_ machine: String, _ nonce: String) async throws -> (instance: String, proof: String)
        let failure: (CloudAPIError) -> AgentPaneRemoteApprovals.Failure
    }

    /// Restarts `session`'s acpmux with a new key; nil on success, else what failed.
    func restartWithApprovals(_ session: CloudMachineSession) async -> AgentPaneRemoteApprovals.Failure? {
        await restartWithApprovals(machine: session.machineID, route: session.appLink != nil ? workerApprovalsRoute() : legacyApprovalsRoute())
    }

    /// Prepares a Cloud machine's acpmux for a new chat when the remote daemon has said that a
    /// keyed restart is safe, or when an older daemon's status shows it is idle. The shared
    /// preparation actor serializes starts per machine; a busy or failed machine quietly falls
    /// back to the unkeyed chat start so the user's Allow flow can show its normal restart notice.
    func restartWithApprovalsIfIdle(_ session: CloudMachineSession, _ preparation: AgentPaneRemoteApprovals.Preparation) async -> Bool {
        await Self.prepareRemoteApprovals(machine: session.machineID, preparation: preparation,
                                          idle: { [machineAPI] in await Self.idleCloudDaemon(session.machineID, api: machineAPI) },
                                          restart: { [self] in await restartWithApprovals(session) })
    }

    /// The preparation policy is kept separate from the Cloud session so its busy and failure
    /// fallbacks stay deterministic in unit tests and for both Cloud API routes.
    static func prepareRemoteApprovals(
        machine: String,
        preparation: AgentPaneRemoteApprovals.Preparation,
        idle: @escaping @Sendable () async -> Bool,
        restart: @escaping @Sendable () async -> AgentPaneRemoteApprovals.Failure?
    ) async -> Bool {
        switch preparation {
        case .daemonSaidSafe:
            return await RemoteApprovalPreparations.shared.run(machine: machine, keepBusy: false) {
                await restart() == nil
            }
        case .checkStatus:
            if AcpmuxRemotePersonKeys.shared.instance(machine: machine) != nil { return true }
            return await RemoteApprovalPreparations.shared.run(machine: machine, keepBusy: true) {
                guard await idle() else { return false }
                return await restart() == nil
            }
        }
    }

    /// Reads the daemon's status through the authenticated Cloud machine route for older
    /// cmux-tui builds that do not serve `agent-session-start-keyed-reason-v1`.
    private static func idleCloudDaemon(_ machine: String, api: CloudAPIClient) async -> Bool {
        let command = [
            "set -eu",
            #"b="$HOME/.cmux/bin/cmux-tui""#,
            #"[ -x "$b" ] || exit 82"#,
            #""$b" acp --json daemon status </dev/null""#,
        ].joined(separator: "; ")
        guard let result = try? await api.exec(machine, command: command, timeoutMs: 10_000),
              result.exitCode == 0,
              let status = RemoteAgentDaemonStatus(json: result.stdout) else { return false }
        return status.idleForKeyedRestart
    }

    /// The shared verifier: new key, keyed start, a fresh nonce, the proof checked against the key, bind.
    func restartWithApprovals(machine: String, route: ApprovalsRoute) async -> AgentPaneRemoteApprovals.Failure? {
        AcpmuxRemotePersonKeys.shared.drop(machine: machine)
        guard let key = AcpmuxSecretKey() else { return .noRandomness }
        do {
            let instance = try await route.keyedStart(machine, AcpmuxSecretKey.lineLength) { key.writeLine(to: $0) }
            guard let nonce = AcpmuxSecretKey.newNonce() else { return .noRandomness }
            // The answer only a run that holds this key can give; the service relays it and
            // cannot make it.
            let held = try await route.personHolds(machine, nonce)
            guard held.instance == instance, key.holds(proof: held.proof, instance: instance, nonce: nonce) else {
                return .keyNotHeld
            }
            AcpmuxRemotePersonKeys.shared.bind(machine: machine, instance: instance, key: key)
            logger.info("remote approvals on for Cloud machine \(machine, privacy: .public)")
            return nil
        } catch let error as CloudAPIError {
            return route.failure(error)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func legacyApprovalsRoute() -> ApprovalsRoute {
        let api = api
        return ApprovalsRoute(
            keyedStart: { machine, length, write in try await api.acpmuxKeyedStart(machine, keyLineLength: length, writeKey: write) },
            personHolds: { machine, nonce in try await api.acpmuxPersonHolds(machine, nonce: nonce) },
            failure: Self.approvalsFailure
        )
    }

    /// The API Worker with the person's Stack session; the team is the install token's team claim
    /// (the team whose CloudDO holds the app server's machines).
    private func workerApprovalsRoute() -> ApprovalsRoute {
        let auth = auth, identity = installIdentity
        let owner = CloudOwnerAPIClient(
            baseURL: FeedService.apiBaseURL(auth: auth),
            accessToken: { try await auth.tokens().access },
            teamID: { (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) }
        )
        return ApprovalsRoute(
            keyedStart: { machine, length, write in try await owner.acpmuxKeyedStart(machine, keyLineLength: length, writeKey: write) },
            personHolds: { machine, nonce in try await owner.acpmuxPersonHolds(machine, nonce: nonce) },
            failure: Self.workerApprovalsFailure
        )
    }

    /// The pane's reason for a refused or failed keyed start (the web route's `vm_acpmux_*` codes).
    nonisolated static func approvalsFailure(_ error: CloudAPIError) -> AgentPaneRemoteApprovals.Failure {
        guard case let .http(_, code, _, _, _) = error else { return .failed(CloudStrings.apiErrorText(error)) }
        switch code {
        case "vm_acpmux_unsupported": return .daemonTooOld
        case "vm_acpmux_not_running": return .machineNotRunning
        case "vm_acpmux_not_single_owner", "vm_acpmux_team_vm": return .notSingleOwner
        case "vm_acpmux_start_failed": return .daemonTookNoKey(nil)
        case "vm_acpmux_holds_failed": return .keyNotHeld
        default: return .failed(CloudStrings.apiErrorText(error))
        }
    }

    /// The pane's reason for a refused or failed keyed start (the API Worker's codes, backend cloud-acpmux.ts).
    nonisolated static func workerApprovalsFailure(_ error: CloudAPIError) -> AgentPaneRemoteApprovals.Failure {
        guard case let .http(_, code, _, _, _) = error else { return .failed(CloudStrings.apiErrorText(error)) }
        switch code {
        case "cloud.acpmux.unsupported": return .daemonTooOld
        case "cloud.machine.not_running": return .machineNotRunning
        case "cloud.acpmux.not_single_owner", "cloud.acpmux.team_vm": return .notSingleOwner
        case "cloud.acpmux.start_failed": return .daemonTookNoKey(nil)
        case "cloud.acpmux.holds_failed": return .keyNotHeld
        default: return .failed(CloudStrings.apiErrorText(error))
        }
    }
}
