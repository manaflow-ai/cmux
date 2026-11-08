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

    /// Deletes the commands started from `since` (nil: all) to `until` (the click; the direct path has no end).
    public func clear(since: Date?, until: Date, key: String) async throws {
        switch self {
        case .history(let client): try await client.clear(kinds: [.command], since: since, until: until, key: key)
        case .direct(let delete): try await delete(since.map { .startedSince($0) } ?? .all)
        case .none: break
        }
    }

    /// Like ``clear(since:until:key:)``, but the direct path (no end) goes only while `gate` is open: false when it was not
    /// sent, so a clear never deletes commands started after its click.
    public func clear(since: Date?, until: Date, key: String, gate: DirectClearGate) async throws -> Bool {
        if case .direct = self, !gate.take() { return false }
        try await clear(since: since, until: until, key: key)
        return true
    }

    /// Whether a clear may still go as an older daemon's direct delete: only when that daemon was connected at the click, and
    /// only on the first attempt (a retry after a dropped link may land after newer commands), as before the write queue.
    public final class DirectClearGate {
        private var open: Bool

        public init(open: Bool) { self.open = open }

        /// Whether the direct delete may go now; closes the gate.
        public func take() -> Bool {
            defer { open = false }
            return open
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
