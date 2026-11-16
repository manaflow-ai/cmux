public import CmuxNextDaemon
public import Foundation

/// How the App deletes terminal commands on one daemon, decided once it is connected (its capabilities known):
/// through its history module (`history-v1`: ordered, keyed, a clear bounded by its click), else with
/// `delete-terminal-commands` (an older daemon with only `terminal-command-history-v1`), else there is nothing
/// to delete there. A deletion never waits for a capability the daemon does not serve.
public enum CommandDeletionRoute: Sendable {
    /// `clearUntil`: the daemon serves `history-clear-until-v1`, so a clear carries its click as its end.
    case history(DaemonHistoryClient, clearUntil: Bool = true)
    case direct(@Sendable (DeleteTerminalCommandsRequest.Selection) async throws -> Void)
    case none

    /// The route on a connected daemon that serves the capabilities `supports` names.
    public static func of(_ connection: DaemonConnection, supports: (String) -> Bool) -> Self {
        if supports(DaemonHistoryClient.capability) {
            return .history(DaemonHistoryClient(connection: connection), clearUntil: supports(DaemonHistoryClient.clearUntilCapability))
        }
        guard supports(DaemonCapability.terminalCommandHistory.rawValue) else { return .none }
        return .direct { _ = try await connection.request(DeleteTerminalCommandsRequest($0)) }
    }

    /// Deletes the commands started from `since` (nil: all) to `until` (the click). A clear that cannot carry `until` (the
    /// direct path, or a history module without `history-clear-until-v1`) goes only when `unbounded` (sent at the click).
    public func clear(since: Date?, until: Date, unbounded: Bool, key: String) async throws {
        switch self {
        case .history(let client, _): try await client.clear(kinds: [.command], since: since, until: until, unbounded: unbounded, key: key)
        case .direct(let delete):
            guard DaemonHistoryClient.mayClear(bounded: false, unbounded: unbounded, "delete-terminal-commands") else { return }
            try await delete(since.map { .startedSince($0) } ?? .all)
        case .none: break
        }
    }

    /// This route when a clear on it cannot carry its end (``HistoryWriteQueue/enqueueClear(live:_:_:done:)``'s `live`):
    /// the direct path, or a history module that does not serve `history-clear-until-v1`.
    public var unbounded: Self? {
        switch self {
        case .history(_, let clearUntil): clearUntil ? nil : self
        case .direct: self
        case .none: nil
        }
    }

    /// Deletes the command with the daemon's row id `id`.
    public func remove(_ id: UInt64, key: String) async throws {
        switch self {
        case .history(let client, _): try await client.remove(ids: ["command:local/\(id)"], key: key)
        case .direct(let delete): try await delete(.ids([String(id)]))
        case .none: break
        }
    }
}
