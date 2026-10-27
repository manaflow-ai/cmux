public import Foundation

/// History a browser exports as JSON: Safari's History.json (File > Export
/// Browsing Data to File…, `{"history": [{url, title, time_usec,
/// visit_count}]}`) and Chrome's in Google Takeout (BrowserHistory.json or
/// Chrome/History.json, `{"Browser History": [{url, title, time_usec}]}`,
/// one row per visit). Times are microseconds since 1970. One entry per URL,
/// the newest `limit` by last visit; only web pages and files
/// (`ImportableURL`).
public struct ExportedHistory: Sendable {
    public enum Format: String, Sendable {
        case safari
        case chromeTakeout
    }

    public let format: Format
    public let entries: [ImportedHistoryEntry]
    /// Rows left out: an address that is not importable, a missing or corrupt time. Rows merged into
    /// their URL's entry, or past `limit`, are not counted.
    public let skipped: ImportSkipCounts

    /// Whether `head` (a file's first bytes) looks like one of the formats.
    public static func looksLikeHistory(_ head: String) -> Bool {
        head.first == "{" && (head.contains("\"history\"") || head.contains("\"Browser History\""))
    }

    /// Nil when `json` is neither format.
    public init?(json data: Data, limit: Int = ImportPlan.defaultHistoryLimit) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let format: Format
        let rows: [[String: Any]]
        if let safari = object["history"] as? [[String: Any]] {
            (format, rows) = (.safari, safari)
        } else if let takeout = object["Browser History"] as? [[String: Any]] {
            (format, rows) = (.chromeTakeout, takeout)
        } else {
            return nil
        }
        var byURL: [URL: ImportedHistoryEntry] = [:]
        var skipped = ImportSkipCounts()
        for row in rows {
            guard let text = row["url"] as? String, let url = ImportableURL.parse(text) else {
                skipped.notImportable += 1
                continue
            }
            // A visit with no time, or one outside years 1-9999, is counted as the database readers count it.
            guard let microseconds = (row["time_usec"] as? NSNumber)?.doubleValue, microseconds > 0,
                  let visit = BrowserTime().unix(microseconds / 1_000_000) else {
                skipped.badTime += 1
                continue
            }
            let visits = format == .safari ? max((row["visit_count"] as? NSNumber)?.intValue ?? 1, 1) : 1
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard var entry = byURL[url] else {
                byURL[url] = ImportedHistoryEntry(url: url, title: title, visitCount: visits, lastVisit: visit)
                continue
            }
            entry.addVisits(visits)
            if visit > entry.lastVisit {
                entry.lastVisit = visit
                entry.title = title ?? entry.title
            }
            byURL[url] = entry
        }
        self.format = format
        entries = Array(byURL.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(max(limit, 0)))
        self.skipped = skipped
    }
}
