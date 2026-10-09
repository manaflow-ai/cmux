import CmuxNextDaemon
import CmuxNextPalette
import Foundation

/// Decodes the daemon's `palette-usage-v1` values into the palette's
/// history mirror, and former local histories into import rows. Values are
/// the daemon's; nothing here computes a score.
nonisolated enum PaletteUsageWire {
    /// One `PaletteUsageRow` / `PaletteUsagePick` (decimal fields are strings).
    private struct Row: Decodable {
        var key: String
        var score: Double
        var last_used_ms: String
    }

    private struct Pick: Decodable {
        var prefix: String
        var key: String
        var score: Double
        var last_used_ms: String
        var last: Bool
    }

    private struct Snapshot: Decodable {
        var revision: String
        var half_life_ms: String
        var pick_half_life_ms: String
        var entries: [Row]
        var picks: [Pick]
        var imported: [String]
    }

    static func date(_ milliseconds: String) -> Date {
        Date(timeIntervalSince1970: (Double(milliseconds) ?? 0) / 1000)
    }

    static func milliseconds(_ date: Date) -> String {
        String(UInt64(max(0, date.timeIntervalSince1970 * 1000)))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private static func pick(_ pick: Pick) -> FrecencyStore.Pick {
        FrecencyStore.Pick(prefix: pick.prefix, key: pick.key, score: pick.score, lastUsed: date(pick.last_used_ms), isLast: pick.last)
    }

    /// `PaletteUsageSnapshot` -> the whole mirror, its revision and the imported sources.
    static func history(_ value: JSONValue) throws -> (history: FrecencyStore, revision: UInt64, imported: Set<String>) {
        let snapshot = try decode(Snapshot.self, value)
        var history = FrecencyStore()
        history.replace(
            entries: Dictionary(snapshot.entries.map { ($0.key, FrecencyStore.Entry(score: $0.score, lastUsed: date($0.last_used_ms))) },
                                uniquingKeysWith: { first, _ in first }),
            picks: snapshot.picks.map(pick),
            halfLife: (Double(snapshot.half_life_ms) ?? 0) / 1000,
            pickHalfLife: (Double(snapshot.pick_half_life_ms) ?? 0) / 1000
        )
        return (history, UInt64(snapshot.revision) ?? 0, Set(snapshot.imported))
    }

    /// A former local history as `palette_usage.import` rows: only rows the
    /// catalog accepts (a key of 1 to 512 characters, a positive finite
    /// score), at most 500, so one damaged history never fails its import.
    static func importRows(_ history: FrecencyStore) -> [JSONValue] {
        history.entries
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty && $0.key.count <= 512
                && $0.value.score.isFinite && $0.value.score > 0 }
            .sorted { $0.key < $1.key }
            .prefix(500)
            .map { key, entry in
            .object(["key": .string(key), "score": .number(entry.score), "last_used_ms": .string(milliseconds(entry.lastUsed))])
        }
    }

    /// The former per-build histories on this Mac: every cmux defaults
    /// domain's `cmuxNext.palette.frecency.v1` (each dogfood tag had its own),
    /// by domain. Read once at import; never written.
    static func legacyHistories(preferences: URL, key: String = "cmuxNext.palette.frecency.v1") -> [(source: String, history: FrecencyStore)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: preferences, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("com.cmuxterm.app") && $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                // concurrency-allow: called from the detached first-import task; this legacy read never runs on the main actor.
                guard let data = try? Data(contentsOf: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let stored = plist[key] as? Data,
                      let history = try? JSONDecoder().decode(FrecencyStore.self, from: stored),
                      !history.entries.isEmpty else { return nil }
                return (file.deletingPathExtension().lastPathComponent, history)
            }
    }
}
