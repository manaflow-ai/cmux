public import Foundation

/// A finished main-frame navigation in one browser profile.
public nonisolated struct BrowserVisit: Hashable, Sendable {
    public var id: Int64
    public var url: String
    public var title: String?
    public var time: Date
    /// The tab (`<machine>/<tab id>`) that visited it, when known.
    public var tab: String?

    public init(id: Int64, url: String, title: String?, time: Date, tab: String?) {
        self.id = id
        self.url = url
        self.title = title
        self.time = time
        self.tab = tab
    }
}

/// One URL with its visits summed (the omnibar's history source).
public nonisolated struct BrowserVisitSummary: Hashable, Sendable {
    public var url: String
    public var title: String?
    public var visitCount: Int
    public var lastVisit: Date
}

/// The page visit log of one browser profile (plans/cmux-next/history.md 2,
/// `page`): an app-local SQLite file, after Chromium's `History` model. Every call
/// runs on this actor, never on the main thread; the database opens on
/// first use. Incognito never gets one.
public actor BrowserVisitLog {
    public static let retention: TimeInterval = 90 * 86_400
    public static let maxVisits = 100_000

    private let url: URL?
    private var database: HistorySQLite?
    private var openFailed = false
    private let clock: @Sendable () -> Date

    /// `url` nil keeps the log in memory (tests, demos).
    public init(url: URL?, clock: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.clock = clock
    }

    /// `<Application Support>/<bundle id>/BrowserProfiles/<profile>/History.sqlite`.
    public static func fileURL(profile: String, supportDirectory: URL) -> URL {
        supportDirectory.appending(path: "BrowserProfiles", directoryHint: .isDirectory)
            .appending(path: profile, directoryHint: .isDirectory)
            .appending(path: "History.sqlite")
    }

    public func record(url: String, title: String?, tab: String?, at time: Date) {
        guard let db = open() else { return }
        try? db.run("INSERT INTO visits(url, title, visit_time_ms, tab) VALUES (?, ?, ?, ?)",
                    [.text(url), title.map(HistorySQLite.Value.text) ?? .null, .integer(Self.ms(time)), tab.map(HistorySQLite.Value.text) ?? .null])
    }

    /// Sets the title of `url`'s newest visit (titles arrive after the load).
    public func updateTitle(_ title: String, for url: String) {
        guard let db = open() else { return }
        try? db.run("""
            UPDATE visits SET title = ? WHERE id = (SELECT id FROM visits WHERE url = ? ORDER BY visit_time_ms DESC, id DESC LIMIT 1)
            """, [.text(title), .text(url)])
    }

    /// Visits newest first, optionally filtered by `text` (every token in
    /// the URL or title) and by `since`.
    public func visits(matching text: String = "", since: Date? = nil, limit: Int = 500) -> [BrowserVisit] {
        guard let db = open() else { return [] }
        var sql = "SELECT id, url, title, visit_time_ms, tab FROM visits WHERE visit_time_ms >= ?"
        var bindings: [HistorySQLite.Value] = [.integer(since.map(Self.ms) ?? 0)]
        for token in HistoryQuery.tokens(text) {
            sql += " AND (url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')"
            let pattern = "%" + Self.escapeLike(token) + "%"
            bindings += [.text(pattern), .text(pattern)]
        }
        sql += " ORDER BY visit_time_ms DESC, id DESC LIMIT ?"
        bindings.append(.integer(Int64(max(0, limit))))
        var result: [BrowserVisit] = []
        try? db.run(sql, bindings) { row in
            result.append(BrowserVisit(id: row.integer(0), url: row.text(1) ?? "", title: row.text(2),
                                       time: Self.date(row.integer(3)), tab: row.text(4)))
        }
        return result
    }

    /// One row per URL, most recent first (seeds the omnibar suggestions).
    public func summaries(limit: Int = 5_000) -> [BrowserVisitSummary] {
        guard let db = open() else { return [] }
        var result: [BrowserVisitSummary] = []
        try? db.run("""
            SELECT url, (SELECT title FROM visits v2 WHERE v2.url = v.url AND v2.title IS NOT NULL ORDER BY visit_time_ms DESC LIMIT 1),
                   COUNT(*), MAX(visit_time_ms)
            FROM visits v GROUP BY url ORDER BY MAX(visit_time_ms) DESC LIMIT ?
            """, [.integer(Int64(limit))]) { row in
            result.append(BrowserVisitSummary(url: row.text(0) ?? "", title: row.text(1),
                                              visitCount: Int(row.integer(2)), lastVisit: Self.date(row.integer(3))))
        }
        return result
    }

    @discardableResult
    public func remove(visit id: Int64) -> Int {
        delete("DELETE FROM visits WHERE id = ?", [.integer(id)])
    }

    /// Removes every visit of `url` (Shift-Delete on an omnibar row).
    @discardableResult
    public func remove(url: String) -> Int {
        delete("DELETE FROM visits WHERE url = ?", [.text(url)])
    }

    /// Removes every visit whose host is `host` or a subdomain of it.
    @discardableResult
    public func remove(host: String) -> Int {
        let host = host.lowercased()
        var ids: [Int64] = []
        guard let db = open() else { return 0 }
        try? db.run("SELECT id, url FROM visits") { row in
            if let text = row.text(1), let candidate = URL(string: text)?.host()?.lowercased(),
               candidate == host || candidate.hasSuffix("." + host) {
                ids.append(row.integer(0))
            }
        }
        return ids.reduce(0) { $0 + remove(visit: $1) }
    }

    /// Removes visits at or after `since` (nil: everything).
    @discardableResult
    public func removeVisits(since: Date?) -> Int {
        delete("DELETE FROM visits WHERE visit_time_ms >= ?", [.integer(since.map(Self.ms) ?? Int64.min)])
    }

    /// Drops visits older than the retention and beyond the row cap.
    @discardableResult
    public func prune() -> Int {
        let cutoff = Self.ms(clock().addingTimeInterval(-Self.retention))
        var removed = delete("DELETE FROM visits WHERE visit_time_ms < ?", [.integer(cutoff)])
        removed += delete("""
            DELETE FROM visits WHERE id IN (SELECT id FROM visits ORDER BY visit_time_ms DESC, id DESC LIMIT -1 OFFSET ?)
            """, [.integer(Int64(Self.maxVisits))])
        return removed
    }

    public func count() -> Int {
        guard let db = open() else { return 0 }
        var total = 0
        try? db.run("SELECT COUNT(*) FROM visits") { total = Int($0.integer(0)) }
        return total
    }

    private func delete(_ sql: String, _ bindings: [HistorySQLite.Value]) -> Int {
        guard let db = open() else { return 0 }
        do {
            try db.run(sql, bindings)
            return db.changes
        } catch {
            return 0
        }
    }

    private func open() -> HistorySQLite? {
        if let database { return database }
        guard !openFailed else { return nil }
        do {
            let db = try HistorySQLite(url: url)
            try db.execute("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS visits(
                  id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT,
                  visit_time_ms INTEGER NOT NULL, tab TEXT);
                CREATE INDEX IF NOT EXISTS visits_time ON visits(visit_time_ms);
                CREATE INDEX IF NOT EXISTS visits_url ON visits(url);
                PRAGMA user_version=1;
                """)
            database = db
            return db
        } catch {
            openFailed = true
            return nil
        }
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
