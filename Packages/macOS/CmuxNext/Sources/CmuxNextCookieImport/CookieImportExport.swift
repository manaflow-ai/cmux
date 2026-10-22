public import CmuxNextActions
import Foundation

/// What `cmux browser cookie-imports` answers an agent or a script (`browser.cookieImports` run
/// by anyone but the person): the browsers it can ask to import from (``CookieSourceListing``)
/// and the audit records, newest first, each without cookie names or values (sites and counts
/// only, so the list itself reveals no session).
public struct CookieImportExport: Sendable {
    /// The audit records.
    public var records: [CookieImportRecord]
    /// The browsers on this Mac.
    public var sources: CookieSourceListing

    /// Creates the export.
    public init(records: [CookieImportRecord], sources: CookieSourceListing) {
        self.records = records
        self.sources = sources
    }

    /// The refusal of a removal that names no import.
    public static var missingID: String { CookieImportStrings.missingImportID }

    /// The action's result fields: `browsers` and `imports` (JSON arrays) and `text` (one line each).
    public var fields: [String: ActionResultValue] {
        ["browsers": .string(sources.json), "imports": .string(importsJSON), "text": .string(text)]
    }

    /// `[{id, date, outcome, requester, reason, from, into, sites: {host: count}, removed}]`, newest first.
    var importsJSON: String {
        let formatter = ISO8601DateFormatter()
        let list: [[String: Any]] = records.reversed().map { record in
            var sites: [String: Int] = [:]
            for site in record.sites { sites[site.host] = site.count }
            var item: [String: Any] = [
                "id": record.id, "date": formatter.string(from: record.date), "outcome": record.outcome.rawValue,
                "requester": ["kind": record.requester.kind, "name": record.requester.name], "reason": record.reason,
                "from": record.source, "into": record.targetProfileName, "requestedSites": record.requestedSites, "sites": sites,
                "removed": record.removedAt != nil,
            ]
            if let failure = record.failure { item["failure"] = failure }
            return item
        }
        let data = (try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The browsers, then one line per import, newest first.
    var text: String {
        let formatter = ISO8601DateFormatter()
        let imports = records.reversed().map { record in
            let removed = record.removedAt != nil ? " (removed)" : ""
            return "\(record.id)  \(formatter.string(from: record.date))  \(record.outcome.rawValue)\(removed)  \(record.source) -> \(record.targetProfileName)  "
                + "\(record.sites.count) sites, \(record.cookies.count) cookies"
        }
        return (["Browsers:", sources.text, "", "Imports:"] + (imports.isEmpty ? ["none"] : imports)).joined(separator: "\n")
    }
}
