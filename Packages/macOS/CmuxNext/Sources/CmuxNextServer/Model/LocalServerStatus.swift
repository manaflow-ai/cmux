public import Foundation

/// Maps the bundled CLI's `cmux server status --json` and `cmux host roles
/// --json` (`<state>/roles/status.json`) into a `ServerSnapshot`. Pure, so
/// tests pin it over fixture JSON.
///
/// Tolerant by design: the server owns these documents and a newer one may
/// add fields, so unknown keys are ignored, unknown roles and malformed
/// entries are dropped, unknown states read as unavailable, and a field
/// the status does not carry yet (pairing, checks, devices) reads as empty.
/// A top level that is not a JSON object is `Malformed`; an object with
/// neither `enabled` nor `service` is `NotServerStatus` (a `cmux` without
/// the server verbs answers `server status` with its terminal daemon's).
public nonisolated enum LocalServerStatus {
    public struct Malformed: Error, Equatable {}
    public struct NotServerStatus: Error, Equatable {}

    public static func snapshot(status: Data, roles: Data?, hostName: String) throws -> ServerSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: status) as? [String: Any] else { throw Malformed() }
        guard root["enabled"] != nil || root["service"] != nil else { throw NotServerStatus() }
        let processRoles = roles.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let service = root["service"] as? [String: Any]
        let mode = string(root["mode"]).flatMap(ServerInstallMode.init(rawValue:)) ?? .user
        return ServerSnapshot(
            hostName: string(root["host_name"]) ?? hostName,
            platform: string(root["platform"]).flatMap(ServerPlatform.init(rawValue:)) ?? .macOS,
            enabled: bool(root["enabled"]) ?? bool(service?["installed"]) ?? false,
            mode: mode,
            roles: roleStatuses(processRoles?["roles"] ?? root["roles"], postgres: root["postgres"]),
            terminals: int(root["terminals"]) ?? 0,
            appServers: objects(root["app_servers"] ?? root["apps"]).compactMap(appServer),
            databases: objects(root["databases"]).compactMap(database),
            browser: browser(root["browser"] as? [String: Any]),
            automations: int(root["automations"]) ?? 0,
            pairing: pairing(root["pairing"] as? [String: Any]),
            devices: objects(root["devices"]).compactMap(device),
            checks: (root["checks"] as? [Any] ?? []).compactMap(string).map(HealthCheckID.init(rawValue:)),
            alerts: objects(root["alerts"]).compactMap(alert),
            store: store(root["store"] as? [String: Any]))
    }

    /// A process role's state (`RoleState`, kebab-case) as the panel reads it.
    public static func roleState(_ raw: String) -> ServerRoleState {
        switch raw {
        case "ready", "on", "running": .on
        case "starting", "backoff": .starting
        case "stopped", "stopping", "exited", "off": .off
        case "crash-loop", "invalid", "failed": .failed
        default: .unavailable
        }
    }

    // MARK: - Sections

    /// Roles from `{roles: [{name, state, ...}]}` (process roles) or a
    /// `{name: state}` map; names that are not a known role are dropped.
    /// Without a `postgres` role, the cluster's own state stands in for it.
    private static func roleStatuses(_ value: Any?, postgres: Any?) -> [ServerRoleStatus] {
        var states: [ServerRole: ServerRoleState] = [:]
        if let map = value as? [String: Any] {
            for (name, state) in map {
                guard let role = ServerRole(rawValue: name), let state = string(state) else { continue }
                states[role] = roleState(state)
            }
        } else {
            for entry in objects(value) {
                guard let name = string(entry["name"]), let role = ServerRole(rawValue: name) else { continue }
                states[role] = roleState(string(entry["state"]) ?? "")
            }
        }
        if states[.postgres] == nil, let cluster = string((postgres as? [String: Any])?["state"]) {
            switch cluster {
            case "running": states[.postgres] = .on
            case "stopped": states[.postgres] = .off
            default: break
            }
        }
        return ServerRole.allCases.compactMap { role in states[role].map { ServerRoleStatus(role, $0) } }
    }

    private static func appServer(_ entry: [String: Any]) -> ServerAppServer? {
        guard let id = string(entry["app"]) ?? string(entry["id"]) else { return nil }
        return ServerAppServer(
            appID: id, name: string(entry["name"]) ?? id,
            state: string(entry["state"]).flatMap(AppServerState.init(rawValue:)) ?? .stopped,
            leaseEpoch: UInt64(max(int64(entry["lease_epoch"]) ?? 0, 0)), holdsLease: bool(entry["holds_lease"]) ?? false,
            durability: string(entry["durability"]).flatMap(AppDataDurability.init(rawValue:)) ?? .bounded,
            lastRestart: int64(entry["last_restart_ms"]).map(date))
    }

    private static func database(_ entry: [String: Any]) -> ServerDatabase? {
        guard let app = string(entry["app"]) else { return nil }
        return ServerDatabase(app: app, sizeBytes: int64(entry["size_bytes"]) ?? 0, quotaBytes: int64(entry["quota_bytes"]) ?? 0)
    }

    private static func browser(_ entry: [String: Any]?) -> ServerBrowserState {
        switch string(entry?["state"]) {
        case "idle": .idle
        case "running": .running(pages: int(entry?["pages"]) ?? 0)
        case "unavailable": .unavailable
        default: .off
        }
    }

    private static func pairing(_ entry: [String: Any]?) -> ServerPairingState {
        guard let entry else { return .unpaired(nil) }
        switch string(entry["state"]) {
        case "paired":
            return .paired(ServerPairing(team: string(entry["team"]) ?? "", owner: string(entry["owner"]) ?? "",
                                         hostID: string(entry["host"]) ?? ""))
        case "pairing":
            return .pairing
        default:
            guard let code = string(entry["code"]), let expires = int64(entry["expires_at_ms"]) else { return .unpaired(nil) }
            return .unpaired(PairingOffer(
                code: PairingCode.normalize(code), expiresAt: date(expires),
                words: (entry["words"] as? [Any] ?? []).compactMap(string), fingerprint: string(entry["fingerprint"]) ?? ""))
        }
    }

    private static func device(_ entry: [String: Any]) -> ServerDevice? {
        guard let id = string(entry["id"]), let kind = string(entry["kind"]).flatMap(ServerDevice.Kind.init(rawValue:)) else { return nil }
        return ServerDevice(id: id, name: string(entry["name"]) ?? id, kind: kind, lastSeen: int64(entry["last_seen_ms"]).map(date))
    }

    private static func alert(_ entry: [String: Any]) -> HealthAlert? {
        guard let check = string(entry["check"]), let raised = int64(entry["raised_at_ms"]) else { return nil }
        let fix = (entry["fix"] as? [String: Any]).flatMap { fix in
            string(fix["title"]).map {
                HealthFix(title: $0, needsAdmin: bool(fix["needs_admin"]) ?? false, opensSettings: bool(fix["opens_settings"]) ?? false)
            }
        }
        return HealthAlert(
            check: HealthCheckID(check), severity: string(entry["severity"]).flatMap(HealthSeverity.init(rawValue:)) ?? .warning,
            title: string(entry["title"]) ?? check, body: string(entry["body"]) ?? "", fix: fix,
            raisedAt: date(raised), resolvedAt: int64(entry["resolved_at_ms"]).map(date))
    }

    /// `store.pinned` is the pinned version (a string) or null; a boolean is accepted too.
    private static func store(_ entry: [String: Any]?) -> ServerStoreInfo {
        let pinned = bool(entry?["pinned"]) ?? (string(entry?["pinned"]).map { !$0.isEmpty } ?? false)
        return ServerStoreInfo(version: string(entry?["version"]) ?? "", channel: string(entry?["channel"]) ?? "", pinned: pinned)
    }

    // MARK: - Lenient scalars

    private static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    /// JSON booleans only (NSNumber 0/1 from a number field is not a flag).
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }

    private static func int(_ value: Any?) -> Int? { int64(value).map { Int(clamping: $0) } }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
