import CmuxNextActions
import Foundation
import CmuxNextControl
import CmuxNextSettings

// Account and Cloud machine state for the iOS dogfood launcher and agents:
// `auth.status` (signed in, email) and `cloud.machines`. Short main-actor
// reads of observable state; no network.
extension AppControl {
    func registerCloudMethods(_ services: AppServices) {
        service?.router.register([
            .mainActor("auth.status") { _ in
                let cloud = services.cloud
                let user = cloud.auth.user
                return .value(.object([
                    "signed_in": .bool(cloud.isSignedIn),
                    "restoring": .bool(cloud.auth.isRestoring),
                    "email": user?.primaryEmail.map(JSONValue.string) ?? .null,
                    // The old app's shape, read by the iOS dogfood launcher.
                    "user": user.map { .object(["id": .string($0.id), "email": $0.primaryEmail.map(JSONValue.string) ?? .null]) } ?? .null,
                    "user_id": user.map { .string($0.id) } ?? .null,
                    "team_id": cloud.auth.teamID.map(JSONValue.string) ?? .null,
                    "backend": .string(cloud.configuration.apiBaseURL.absoluteString),
                    "cloud_unavailable": cloud.unavailableReason.map(JSONValue.string) ?? .null,
                ]))
            },
            .mainActor("cloud.machines") { _ in
                if let refusal = Self.policyRefusal("cloud.machines", disabled: services.registry.disabledFeatures) { throw refusal }
                let rows: [JSONValue] = services.machines.cloud.map { .object(Self.cloudMachineRow($0, services.machines)) }
                return .value(.object(["machines": .array(rows), "loaded": .bool(services.cloud.hasLoadedCurrentMachines),
                                       "creations": .array(services.cloud.creations.controlRows),
                                       "last_error": services.cloud.lastError.map(JSONValue.string) ?? .null]))
            },
        ])
        // Tagged DEV builds only (debug.* methods; a release build registers
        // none, and ControlRouter drops them too).
        #if DEBUG
        service?.router.register([
            // Starts this Mac's cmux link the way a connect does and reports
            // the ensure and the apps-link-changed answer (cx-rtipa S3).
            .async("debug.cloud.link_ensure") { [weak services] _ in
                let found = await MainActor.run { () -> (CloudService?, ControlError?) in
                    guard let services else { return (nil, nil) }
                    return (services.cloud, Self.policyRefusal("debug.cloud.link_ensure", disabled: services.registry.disabledFeatures))
                }
                if let refusal = found.1 { throw refusal }
                guard let cloud = found.0 else { return .null }
                // The daemon wire value, as this socket's JSON value.
                let report = await cloud.ensureLinkReport()
                guard let data = try? JSONEncoder().encode(report),
                      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
                return CmuxNextSettings.JSONValue(foundation: object) ?? .null
            },
            // Ends the Cloud session here without the app's sign-out (as an
            // expired or remote sign-out does), for the link's GUI proof.
            .async("debug.cloud.end_session") { [weak services] _ in
                guard let cloud = await MainActor.run(body: { services?.cloud }) else { return .null }
                await cloud.auth.signOut()
                return .object(["ended": .bool(true)])
            },
        ])
        #endif
    }

    /// One Cloud machine's row of `cloud.machines` (and of the Cloud
    /// diagnostics' details): its record, stage, daemon link state and the
    /// capability negotiation of its daemon.
    static func cloudMachineRow(_ session: CloudMachineSession, _ machines: MachineRegistry) -> [String: JSONValue] {
        let store = session.daemon.store
        let state: String = switch store.connectionState {
        case .connected: "connected"
        case .connecting: "connecting"
        case .disconnected: "disconnected"
        case .failed(let reason): "failed: \(reason)"
        }
        let compat = machines.compatibility(of: session.daemon)
        return [
            "id": .string(session.machineID),
            // The id its daemon has in the machine catalog (`machine list --catalog`),
            // so `cmux machine list` lists a connected machine once.
            "machine_id": session.daemon.identity?.machineResourceID.map { .string($0.rawValue) } ?? .null,
            "title": .string(session.machine.title),
            // The record's status, except a connected daemon is running (cx-lu8f).
            "status": .string(session.effectiveStatus.rawValue),
            "api_status": .string(session.machine.status.rawValue),
            "stage": .string(session.stage.name),
            "stage_detail": session.stage.failure.map(JSONValue.string) ?? .null,
            // Why a paused machine is paused (`idle` or `user`), and its idle auto-pause (0: Off).
            "pause_reason": session.machine.pauseReason.map { .string($0.rawValue) } ?? .null,
            "idle_pause_minutes": session.machine.idlePauseMinutes.map { .number(Double($0)) } ?? .null,
            "daemon": .string(state),
            // Capability negotiation per machine (DaemonCompatibility).
            "session_id": compat?.sessionID.map(JSONValue.string) ?? .null,
            "session": compat?.sessionName.map(JSONValue.string) ?? .null,
            "protocol": compat?.protocolVersion.map { .number(Double($0)) } ?? .null,
            "daemon_version": compat.map { .string($0.version) } ?? .null,
            "daemon_commit": compat?.buildCommit.map(JSONValue.string) ?? .null,
            "compatibility": compat.map { .string($0.level.rawValue) } ?? .null,
            "missing_required": .array((compat?.missingRequired ?? []).map(JSONValue.string)),
            "missing_features": .array((compat?.missingOptional ?? []).map(JSONValue.string)),
            "workspaces": .array(store.workspaces.map { .object(["id": .string($0.id), "name": .string($0.displayName)]) }),
        ]
    }
}
