import CmuxNextControl
import CmuxNextSettings
import CmuxNextErrorJournal
import Foundation

/// `errors.list` and `errors.clear` (`cmux errors`): the error journal of this build.
///
/// `errors.list` params: `since_ms` (unix ms) or `since` (`90s`, `15m`, `2h`, `3d`),
/// `source` (string or array; `page` matches every `page:<page>`), `level`
/// (warning|error|fault|crash, the least bad to show), `text`, `order` (recent|count),
/// `limit` (default 50, at most 1000), `harvest` (default true: read the logs first).
/// `errors.clear` params: `fingerprints` (array; none clears all).
struct ErrorJournalControl: Sendable {
    let journal: ErrorJournal
    let sources: [any ErrorHarvestSource]

    var methods: [ControlMethod] {
        let control = self
        return [
            ControlMethod.async("errors.list") { call in try await control.list(call.params) }
                .withDeadline(.fixed(.seconds(12))),
            ControlMethod.async("errors.clear") { call in await control.clear(call.params) },
        ]
    }

    func list(_ params: [String: JSONValue]) async throws -> JSONValue {
        let query = try Self.query(params, now: Date())
        var harvested: JSONValue = .null
        if params["harvest"]?.boolValue != false {
            let found = await journal.harvest(sources)
            harvested = .object(found.mapValues { .number(Double($0)) })
        }
        let entries = await journal.entries(query)
        let bytes = await journal.diskBytes
        let total = await journal.entryCount
        let writeError = await journal.writeError
        return .object([
            "dir": .string(journal.directory.path),
            "disk_bytes": .number(Double(bytes)),
            "total": .number(Double(total)),
            "harvested": harvested,
            "write_error": writeError.map(JSONValue.string) ?? .null,
            "entries": .array(entries.map(Self.json)),
        ])
    }

    func clear(_ params: [String: JSONValue]) async -> JSONValue {
        let fingerprints = params["fingerprints"]?.arrayValue?.compactMap(\.stringValue)
        let removed = await journal.clear(fingerprints: fingerprints)
        return .object(["removed": .number(Double(removed))])
    }

    static func query(_ params: [String: JSONValue], now: Date) throws -> ErrorQuery {
        var query = ErrorQuery()
        if let ms = params["since_ms"]?.doubleValue {
            query.since = Date(timeIntervalSince1970: ms / 1000)
        } else if let text = params["since"]?.stringValue {
            guard let seconds = sinceSeconds(text) else {
                throw ControlError.invalidParams(Self.text("errors.invalid.since", "since must look like 90s, 15m, 2h or 3d."))
            }
            query.since = now.addingTimeInterval(-seconds)
        }
        if let source = params["source"]?.stringValue {
            query.sources = [source]
        } else if let sources = params["source"]?.arrayValue {
            query.sources = sources.compactMap(\.stringValue)
        }
        if let level = params["level"]?.stringValue {
            guard let parsed = ErrorLevel(rawValue: level) else {
                throw ControlError.invalidParams(Self.text("errors.invalid.level", "level must be warning, error, fault or crash."))
            }
            query.minimumLevel = parsed
        }
        query.text = params["text"]?.stringValue
        if let order = params["order"]?.stringValue {
            guard let parsed = ErrorQuery.Order(rawValue: order) else {
                throw ControlError.invalidParams(Self.text("errors.invalid.order", "order must be recent or count."))
            }
            query.order = parsed
        }
        if let limit = params["limit"]?.doubleValue { query.limit = min(1000, max(1, Int(limit))) }
        return query
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ErrorJournal", bundle: .module)
    }

    /// `90s`, `15m`, `2h`, `3d` (a bare number is seconds).
    static func sinceSeconds(_ text: String) -> Double? {
        let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        guard let last = text.last else { return nil }
        if let unit = units[last], let value = Double(text.dropLast()), value >= 0 { return value * unit }
        if let value = Double(text), value >= 0 { return value }
        return nil
    }

    static func json(_ entry: ErrorEntry) -> JSONValue {
        .object([
            "fingerprint": .string(entry.fingerprint),
            "source": .string(entry.source),
            "level": .string(entry.level.rawValue),
            "template": .string(entry.template),
            "sample": .string(entry.sample),
            "frame": entry.topFrame.map(JSONValue.string) ?? .null,
            "context": .object(entry.context.mapValues(JSONValue.string)),
            "count": .number(Double(entry.count)),
            "first_ms": .number(Double(entry.firstMs)),
            "last_ms": .number(Double(entry.lastMs)),
        ])
    }
}
