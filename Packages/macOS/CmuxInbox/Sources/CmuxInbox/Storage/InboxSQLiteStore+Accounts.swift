import Foundation
import SQLite3

extension InboxSQLiteStore {
    /// Inserts or updates an account status record.
    ///
    /// The user's notification preference is written only on first insert.
    /// Status upserts from sync, push, and connect must not clobber it, so on
    /// conflict `notifications_enabled` is preserved; it changes only through
    /// ``setNotificationsEnabled(source:accountID:enabled:)``.
    /// - Parameter account: Account to persist.
    public func upsertAccount(_ account: InboxAccount) throws {
        try database.exec("""
        INSERT INTO accounts (
            source, account_id, display_name, status, status_message,
            last_sync_at, capabilities_json, notifications_enabled
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source, account_id) DO UPDATE SET
            display_name = excluded.display_name,
            status = excluded.status,
            status_message = excluded.status_message,
            last_sync_at = excluded.last_sync_at,
            capabilities_json = excluded.capabilities_json;
        """, binding: [
            .text(account.source.rawValue),
            .text(account.accountID),
            .text(account.displayName),
            .text(account.status.rawValue),
            account.statusMessage.map { .text($0) } ?? .null,
            sqliteDate(account.lastSyncAt),
            .text(try encodeJSON(account.capabilities.map(\.rawValue).sorted())),
            .int(account.notificationsEnabled ? 1 : 0),
        ])
    }

    /// Lists all known accounts in stable source order.
    /// - Returns: Persisted accounts.
    public func accounts() throws -> [InboxAccount] {
        let statement = try database.prepare("""
        SELECT source, account_id, display_name, status, status_message,
               last_sync_at, capabilities_json, notifications_enabled
        FROM accounts
        ORDER BY source, account_id;
        """)
        defer { sqlite3_finalize(statement) }
        var rows: [InboxAccount] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw InboxError.stepFailed(step, database.lastErrorMessage()) }
            rows.append(try account(from: statement))
        }
        return rows
    }

    /// Updates the cmux-native notification preference for one account.
    /// - Parameters:
    ///   - source: Source service.
    ///   - accountID: Source account id.
    ///   - enabled: Whether cmux should surface native notifications.
    public func setNotificationsEnabled(
        source: InboxSource,
        accountID: String,
        enabled: Bool
    ) throws {
        try database.exec("""
        UPDATE accounts
        SET notifications_enabled = ?
        WHERE source = ? AND account_id = ?;
        """, binding: [
            .int(enabled ? 1 : 0),
            .text(source.rawValue),
            .text(accountID),
        ])
    }

    func account(from statement: OpaquePointer?) throws -> InboxAccount {
        let source = InboxSource(rawValue: stringFromColumn(statement, 0)) ?? .generic
        let status = InboxAccountStatus(rawValue: stringFromColumn(statement, 3)) ?? .error
        let rawCapabilities: [String] = try decodeJSON([String].self, from: stringFromColumn(statement, 6))
        let capabilities = Set(rawCapabilities.compactMap(InboxConnectorCapability.init(rawValue:)))
        return InboxAccount(
            source: source,
            accountID: stringFromColumn(statement, 1),
            displayName: stringFromColumn(statement, 2),
            status: status,
            statusMessage: optionalStringFromColumn(statement, 4),
            lastSyncAt: dateFromColumn(statement, 5),
            capabilities: capabilities,
            notificationsEnabled: sqlite3_column_int(statement, 7) != 0
        )
    }
}
