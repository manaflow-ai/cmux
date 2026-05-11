import Foundation
import SQLite3

/// Local FTS5-backed index of cmux panel contents.
///
/// Stores chunks of text emitted by terminal scrollback, browser pages,
/// and markdown panels, keyed by (windowID, workspaceID, panelID, kind).
/// Designed for sub-100 ms `MATCH` queries across all live state.
///
/// Status: P1 scaffold. Wiring to terminal/browser capture lives in
/// `SearchIndexer` (TODO). See docs/menubar-global-search.md.
public actor SearchIndex {
    public struct Hit: Sendable, Hashable {
        public let panelID: UUID
        public let workspaceID: UUID
        public let windowID: UUID
        public let kind: Kind
        public let snippet: String
        public let rank: Double
    }

    public enum Kind: String, Sendable {
        case terminal, browser, markdown, title
    }

    private var db: OpaquePointer?
    private let url: URL

    public init(url: URL) throws {
        self.url = url
        try open()
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    private func open() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "SearchIndex", code: 1)
        }
        let schema = """
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
            window_id, workspace_id, panel_id, kind, ts UNINDEXED, anchor UNINDEXED, text,
            tokenize='unicode61 remove_diacritics 2'
        );
        """
        sqlite3_exec(db, schema, nil, nil, nil)
    }

    public func upsert(
        windowID: UUID, workspaceID: UUID, panelID: UUID,
        kind: Kind, anchor: String, text: String
    ) {
        let sql = """
        INSERT INTO chunks(window_id, workspace_id, panel_id, kind, ts, anchor, text)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, windowID.uuidString, -1, nil)
        sqlite3_bind_text(stmt, 2, workspaceID.uuidString, -1, nil)
        sqlite3_bind_text(stmt, 3, panelID.uuidString, -1, nil)
        sqlite3_bind_text(stmt, 4, kind.rawValue, -1, nil)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 6, anchor, -1, nil)
        sqlite3_bind_text(stmt, 7, text, -1, nil)
        sqlite3_step(stmt)
    }

    public func search(_ query: String, limit: Int = 50) -> [Hit] {
        let sql = """
        SELECT window_id, workspace_id, panel_id, kind,
               snippet(chunks, 6, '[', ']', '…', 12) AS snip,
               bm25(chunks) AS r
        FROM chunks WHERE chunks MATCH ? ORDER BY r LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, query, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var hits: [Hit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let wId = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                let wsId = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                let pId = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                let kRaw = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                let snip = sqlite3_column_text(stmt, 4).map({ String(cString: $0) }),
                let kind = Kind(rawValue: kRaw),
                let window = UUID(uuidString: wId),
                let workspace = UUID(uuidString: wsId),
                let panel = UUID(uuidString: pId)
            else { continue }
            hits.append(Hit(
                panelID: panel, workspaceID: workspace, windowID: window,
                kind: kind, snippet: snip,
                rank: sqlite3_column_double(stmt, 5)))
        }
        return hits
    }

    /// Drop all rows for a panel (e.g. on close). Soft retention handled by caller.
    public func purge(panelID: UUID) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM chunks WHERE panel_id = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, panelID.uuidString, -1, nil)
        sqlite3_step(stmt)
    }
}
