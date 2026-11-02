public import CmuxNextDaemon
public import CmuxNextSettings
import Foundation

/// The JSON that Cloud Diagnostics' Copy details copies (and a CLI or MCP run
/// of `cloudDiagnostics` returns as `details`): the account, and a row per
/// Cloud machine. No secrets.
public struct CloudDiagnosticsReport {
    public init() {}
    /// The control socket's JSON (CmuxNextDaemon has its own of the same name).
    public typealias JSONValue = CmuxNextSettings.JSONValue

    /// The account half. `teamName` is the team's display name from the
    /// account's team list, which the app already holds (no request), nil when
    /// the list lacks it; `teamID` stays the UUID.
    public struct Account: Sendable, Equatable {
        public var backend: String
        public var backendKind: String
        public var signedIn: Bool
        public var email: String?
        public var teamID: String?
        public var teamName: String?
        public var unavailable: String?
        public var lastError: String?

        public init(backend: String, backendKind: String, signedIn: Bool, email: String?, teamID: String?, teamName: String?,
                    unavailable: String? = nil, lastError: String? = nil) {
            self.backend = backend
            self.backendKind = backendKind
            self.signedIn = signedIn
            self.email = email
            self.teamID = teamID
            self.teamName = teamName.flatMap { $0.isEmpty ? nil : $0 }
            self.unavailable = unavailable
            self.lastError = lastError
        }
    }

    /// The copied details: the account and every Cloud machine's row, as pretty JSON.
    public static func details(_ account: Account, machines rows: [JSONValue]) -> String {
        let report: JSONValue = .object([
            "backend": .string(account.backend),
            "backend_kind": .string(account.backendKind),
            "signed_in": .bool(account.signedIn),
            "email": jsonText(account.email),
            "team_id": jsonText(account.teamID),
            "team_name": jsonText(account.teamName),
            "unavailable": jsonText(account.unavailable),
            "last_error": jsonText(account.lastError),
            "machines": .array(rows),
        ])
        return (try? DeterministicJSON().string(report.foundationObject, pretty: true)) ?? ""
    }

    /// Who the all-well line names: the email, else the team's name, and the
    /// team's UUID only when the team list has no name for it.
    public static func accountLabel(_ account: Account) -> String {
        account.email ?? account.teamName ?? account.teamID ?? ""
    }

    /// What a machine's daemon said in its handshake (`identify`), which the
    /// text report carried before #23109 and the `cloud.machines` row leaves
    /// out: its build and ghostty commits, every capability it serves (the row
    /// lists only the missing ones), its pid, registry id and generation. The
    /// connected daemon's identity, else the last one that answered; null
    /// before any did. `daemon_reason` is why the link is down.
    public static func daemonDetails(_ state: DaemonConnectionState, last: DaemonIdentity?) -> [String: JSONValue] {
        var identity = last, reason: String?
        switch state {
        case .connected(let current): identity = current
        case .connecting: break
        case .disconnected(let why), .failed(let why): reason = why
        }
        return ["daemon_reason": jsonText(reason), "daemon_identity": identity.map { JSONValue.object(identityFields($0)) } ?? .null]
    }

    /// Every field of `identify`, under its wire name.
    public static func identityFields(_ identity: DaemonIdentity) -> [String: JSONValue] {
        let names = { (list: [String]) in JSONValue.array(list.map(JSONValue.string)) }
        return [
            "app": .string(identity.app),
            "version": .string(identity.version),
            "build_commit": jsonText(identity.buildCommit),
            "build_id": jsonText(identity.buildID),
            "ghostty_commit": jsonText(identity.ghosttyCommit),
            "protocol": .number(Double(identity.protocolVersion)),
            "capabilities": names(identity.capabilities),
            "session": .string(identity.session),
            "pid": .number(Double(identity.pid)),
            "registry_id": jsonText(identity.registryID),
            "machine_id": jsonText(identity.machineResourceID?.rawValue),
            "session_resource_id": jsonText(identity.sessionResourceID?.rawValue),
            "machine_platform": identity.machinePlatform.map { JSONValue.object(["os": jsonText($0.os), "arch": jsonText($0.arch)]) } ?? .null,
            "machine_capabilities": names(identity.machineCapabilities),
            "machine_name": jsonText(identity.machineName),
            "generation": .string(identity.generation.rawValue),
            "workspace_revision": .number(Double(identity.workspaceRevision)),
            "lifecycle_ready": .bool(identity.lifecycleReady),
            "launch_snapshot_path": jsonText(identity.launchSnapshotPath),
            "cli_path": jsonText(identity.cliPath),
        ]
    }

    private static func jsonText(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}
