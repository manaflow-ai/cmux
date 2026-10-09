import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings

// Account and Cloud machine state for the iOS dogfood launcher and agents:
// `auth.status` (signed in, email) and `cloud.machines`. Short main-actor
// reads of observable state; no network.
extension AppControl {
    func registerCloudMethods(_ services: AppServices) {
        service?.router.register([
            .mainActor("auth.status") { _ in
                let cloud = services.cloud!
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
                let rows: [JSONValue] = services.machines.cloud.map { session in
                    let store = session.daemon.store
                    let state: String = switch store.connectionState {
                    case .connected: "connected"
                    case .connecting: "connecting"
                    case .disconnected: "disconnected"
                    case .failed(let reason): "failed: \(reason)"
                    }
                    let compat = services.machines.compatibility(of: session.daemon)
                    let fields: [String: JSONValue] = [
                        "id": .string(session.machineID),
                        "title": .string(session.machine.title),
                        "status": .string(session.machine.status.rawValue),
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
                    return .object(fields)
                }
                return .value(.object(["machines": .array(rows), "last_error": services.cloud.lastError.map(JSONValue.string) ?? .null]))
            },
        ])
    }
}
