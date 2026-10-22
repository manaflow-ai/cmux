import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// The Cloud diagnostics (`cloudDiagnostics`): a one-line summary for a
/// person, and the account, backend and per-machine link state as JSON
/// behind Copy details (and in a CLI or MCP run's result). No secrets.
@MainActor
enum CloudDiagnostics {
    /// The control socket's JSON (CmuxNextDaemon has its own of the same name).
    typealias JSONValue = CmuxNextSettings.JSONValue

    /// A one-line summary for a person, and the details as JSON.
    struct Report {
        var summary: String
        var details: String
    }

    /// The account half of the details. `teamName` is the team's display
    /// name from the account's team list, which the app already holds (no
    /// request), nil when the list lacks it; `teamID` stays the UUID.
    struct Account {
        var backend: String
        var backendKind: String
        var signedIn: Bool
        var email: String?
        var teamID: String?
        var teamName: String?
        var unavailable: String?
        var lastError: String?
    }

    static func report(_ context: AppActionContext) async -> Report {
        let cloud = context.services.cloud, machines = context.services.machines
        var rows: [JSONValue] = []
        for session in machines.cloud {
            var row = AppControl.cloudMachineRow(session, machines)
            row["link_pid"] = .string(await session.link?.pid.map(String.init) ?? (session.appLink == nil ? "none" : "app server"))
            let store = session.daemon.store
            row.merge(daemonDetails(store.connectionState, last: store.identity)) { kept, _ in kept }
            rows.append(.object(row))
        }
        let teamID = cloud.auth.teamID
        let account = Account(
            backend: cloud.configuration.apiBaseURL.absoluteString,
            backendKind: String(describing: cloud.configuration.backend),
            signedIn: cloud.isSignedIn,
            email: cloud.auth.user?.primaryEmail,
            teamID: teamID,
            teamName: teamID.flatMap { id in cloud.auth.teams.first { $0.id == id }?.displayName }.flatMap { $0.isEmpty ? nil : $0 },
            unavailable: cloud.unavailableReason,
            lastError: cloud.lastError)
        return Report(summary: summary(context, account: account), details: details(account, machines: rows))
    }

    /// The copied details: the account and every Cloud machine's row, as
    /// pretty JSON.
    static func details(_ account: Account, machines rows: [JSONValue]) -> String {
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

    /// What a machine's daemon said in its handshake (`identify`), which the
    /// text report carried before #23109 and `cloudMachineRow` leaves out:
    /// its build and ghostty commits, every capability it serves (the row
    /// lists only the missing ones), its pid, registry id and generation.
    /// The connected daemon's identity, else the last one that answered;
    /// null before any did. `daemon_reason` is why the link is down.
    static func daemonDetails(_ state: DaemonConnectionState, last: DaemonIdentity?) -> [String: JSONValue] {
        var identity = last, reason: String?
        switch state {
        case .connected(let current): identity = current
        case .connecting: break
        case .disconnected(let why), .failed(let why): reason = why
        }
        return ["daemon_reason": jsonText(reason), "daemon_identity": identity.map { JSONValue.object(identityFields($0)) } ?? .null]
    }

    /// Every field of `identify`, under its wire name.
    static func identityFields(_ identity: DaemonIdentity) -> [String: JSONValue] {
        let names = { (list: [String]) in JSONValue.array(list.map(JSONValue.string)) }
        return [
            "app": .string(identity.app),
            "version": .string(identity.version),
            "build_commit": jsonText(identity.buildCommit),
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
        ]
    }

    private static func jsonText(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

    /// The first thing that needs the person, else that all is well.
    private static func summary(_ context: AppActionContext, account: Account) -> String {
        let cloud = context.services.cloud, machines = context.services.machines
        if let reason = cloud.unavailableReason { return reason }
        guard cloud.isSignedIn else { return CloudStrings.signInFirst }
        for session in machines.cloud {
            if let failure = session.stage.failure { return "\(session.machine.title): \(failure)" }
            if let compat = machines.compatibility(of: session.daemon), compat.level != .current {
                return "\(session.machine.title): \(CloudStrings.compatibility(compat))"
            }
        }
        return CloudStrings.diagnosticsAllWell(accountLabel(account))
    }

    /// Who the all-well line names: the email, else the team's name, and the
    /// team's UUID only when the team list has no name for it.
    static func accountLabel(_ account: Account) -> String {
        account.email ?? account.teamName ?? account.teamID ?? ""
    }
}
