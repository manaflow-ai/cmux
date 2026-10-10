import CmuxNextDaemon
import CmuxNextPalette
import Foundation

/// Decodes the daemon's `palette-usage-v1` values into the palette's
/// history mirror. Values are the daemon's; nothing here computes a score.
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
}
