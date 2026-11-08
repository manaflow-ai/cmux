public import CmuxNextDaemon
public import Foundation

/// How the App deletes terminal commands on one daemon, decided once it is connected (its capabilities known):
/// through its history module (`history-v1`: ordered, keyed, a clear bounded by its click), else with
/// `delete-terminal-commands` (an older daemon with only `terminal-command-history-v1`), else there is nothing
/// to delete there. A deletion never waits for a capability the daemon does not serve.
public enum CommandDeletionRoute: Sendable {
    case history(DaemonHistoryClient)
    case direct(@Sendable (DeleteTerminalCommandsRequest.Selection) async throws -> Void)
    case none

    /// The route on a connected daemon that serves the capabilities `supports` names.
    public static func of(_ connection: DaemonConnection, supports: (String) -> Bool) -> Self {
        if supports(DaemonHistoryClient.capability) { return .history(DaemonHistoryClient(connection: connection)) }
        guard supports(DaemonCapability.terminalCommandHistory.rawValue) else { return .none }
        return .direct { _ = try await connection.request(DeleteTerminalCommandsRequest($0)) }
    }

    /// Deletes the commands started from `since` (nil: all) to `until` (the click). A clear that cannot carry `until` (the
    /// direct path, or a history module without `history-clear-until-v1`) goes only as `gate` allows (``HistoryClearGate``).
    public func clear(since: Date?, until: Date, gate: HistoryClearGate, key: String) async throws {
        switch self {
        case .history(let client): try await client.clear(kinds: [.command], since: since, until: until, gate: gate, key: key)
        case .direct(let delete):
            guard gate.allows(bounded: false, "delete-terminal-commands") else { return }
            try await delete(since.map { .startedSince($0) } ?? .all)
        case .none: break
        }
    }

    /// Deletes the command with the daemon's row id `id`.
    public func remove(_ id: UInt64, key: String) async throws {
        switch self {
        case .history(let client): try await client.remove(ids: ["command:local/\(id)"], key: key)
        case .direct(let delete): try await delete(.ids([String(id)]))
        case .none: break
        }
    }
}
