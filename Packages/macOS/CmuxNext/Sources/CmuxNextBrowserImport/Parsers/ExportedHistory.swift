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
        for row in rows {
            guard let text = row["url"] as? String, let url = ImportableURL.parse(text) else { continue }
            let microseconds = (row["time_usec"] as? NSNumber)?.doubleValue ?? 0
            let visit = Date(timeIntervalSince1970: microseconds / 1_000_000)
            let visits = format == .safari ? max((row["visit_count"] as? NSNumber)?.intValue ?? 1, 1) : 1
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard var entry = byURL[url] else {
                byURL[url] = ImportedHistoryEntry(url: url, title: title, visitCount: visits, lastVisit: visit)
                continue
            }
            entry.visitCount += visits
            if visit > entry.lastVisit {
                entry.lastVisit = visit
                entry.title = title ?? entry.title
            }
            byURL[url] = entry
        }
        self.format = format
        entries = Array(byURL.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(max(limit, 0)))
    }
}
