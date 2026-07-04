public import Foundation
import SQLite3

/// Local SQLite source of truth for normalized inbox accounts, threads, items, drafts, and search.
public actor InboxSQLiteStore {
    private static let schemaVersion: Int32 = 1
    let database: InboxDatabase
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    /// Creates a store at the default cmux inbox path.
    /// - Parameter databaseURL: Database URL; defaults to `~/.cmuxterm/inbox.sqlite3`.
    public init(databaseURL: URL? = nil) throws {
        let url = databaseURL ?? Self.defaultDatabaseURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        database = try InboxDatabase(path: url.path)
        try Self.migrate(database)
    }

    deinit {
        database.close()
    }

    /// Returns the default on-disk inbox database URL.
    /// - Parameter homeDirectory: Home directory to use for path construction.
    public static func defaultDatabaseURL(
        homeDirectory: URL? = nil
    ) -> URL {
        let root = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("inbox.sqlite3", isDirectory: false)
    }

    /// Runs idempotent schema migrations. Internal test seam reached through
    /// `@testable import`; not part of the public package API.
    func runMigrationsForTesting() throws {
        try Self.migrate(database)
    }

    private static func migrate(_ database: InboxDatabase) throws {
        let version = try database.userVersion()
        guard version < Self.schemaVersion else { return }
        try database.transaction {
            if version < 1 {
                try createVersion1Schema(database)
                try database.setUserVersion(1)
            }
        }
    }

    private static func createVersion1Schema(_ database: InboxDatabase) throws {
        try database.exec("""
        CREATE TABLE IF NOT EXISTS accounts (
            source TEXT NOT NULL,
            account_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            status TEXT NOT NULL,
            status_message TEXT,
            last_sync_at REAL,
            capabilities_json TEXT NOT NULL,
            notifications_enabled INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (source, account_id)
        );
        """)
        try database.exec("""
        CREATE TABLE IF NOT EXISTS threads (
            thread_id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            account_id TEXT NOT NULL,
            external_thread_id TEXT NOT NULL,
            participants_json TEXT NOT NULL,
            title TEXT NOT NULL,
            unread_count INTEGER NOT NULL DEFAULT 0,
            last_activity_at REAL NOT NULL,
            muted INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0,
            external_url TEXT,
            metadata_json TEXT NOT NULL,
            UNIQUE (source, account_id, external_thread_id)
        );
        """)
        try database.exec("""
        CREATE TABLE IF NOT EXISTS items (
            item_id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            source TEXT NOT NULL,
            account_id TEXT NOT NULL,
            external_message_id TEXT NOT NULL,
            sender_name TEXT NOT NULL,
            sender_address TEXT,
            timestamp REAL NOT NULL,
            body_preview TEXT NOT NULL,
            body TEXT,
            metadata_json TEXT NOT NULL,
            unread INTEGER NOT NULL DEFAULT 1,
            actionable INTEGER NOT NULL DEFAULT 0,
            draft_id TEXT,
            external_url TEXT,
            UNIQUE (source, account_id, external_message_id)
        );
        """)
        try database.exec("""
        CREATE TABLE IF NOT EXISTS drafts (
            draft_id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            source TEXT NOT NULL,
            account_id TEXT NOT NULL,
            instruction TEXT,
            body TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            approved_at REAL,
            sent_at REAL,
            error_message TEXT
        );
        """)
        try database.exec("""
        CREATE TABLE IF NOT EXISTS sync_state (
            source TEXT NOT NULL,
            account_id TEXT NOT NULL,
            cursor TEXT,
            updated_at REAL NOT NULL,
            PRIMARY KEY (source, account_id)
        );
        """)
        try database.exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS inbox_items_fts USING fts5(
            item_id UNINDEXED,
            thread_id UNINDEXED,
            source UNINDEXED,
            account_id UNINDEXED,
            sender,
            title,
            body_preview,
            body,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)
        try database.exec("CREATE INDEX IF NOT EXISTS idx_items_thread_unread ON items(thread_id, unread);")
        try database.exec("CREATE INDEX IF NOT EXISTS idx_items_source_time ON items(source, timestamp DESC);")
        try database.exec("CREATE INDEX IF NOT EXISTS idx_threads_source_activity ON threads(source, last_activity_at DESC);")
    }
}
