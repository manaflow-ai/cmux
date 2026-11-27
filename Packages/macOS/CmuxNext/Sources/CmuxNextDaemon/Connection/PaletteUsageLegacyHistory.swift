public import Foundation

/// The palette's former per-build histories (before `palette-usage-v1`, each
/// dogfood tag kept its own in its UserDefaults domain under
/// `cmuxNext.palette.frecency.v1`), as `palette_usage.import` rows. Read
/// during an explicitly accepted Classic import, off the main actor, never written.
public struct PaletteUsageLegacyHistory: Sendable, Equatable {
    /// The defaults domain the history came from (the import source).
    public let source: String
    /// `PaletteUsageRow` values the catalog accepts (a key of 1 to 512
    /// characters, a positive finite score), at most 500.
    public let rows: [JSONValue]

    /// The former `FrecencyStore` JSON (dates as seconds since the reference date).
    private struct Former: Decodable {
        struct Entry: Decodable {
            var score: Double
            var lastUsed: Double
        }

        var entries: [String: Entry]
    }

    /// Every cmux defaults domain under `preferences` with a former history.
    @concurrent public static func read(preferences: URL, excluding imported: Set<String>,
                                        key: String = "cmuxNext.palette.frecency.v1") async -> [PaletteUsageLegacyHistory] {
        let files = (try? FileManager.default.contentsOfDirectory(at: preferences, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { file in
                let domain = file.deletingPathExtension().lastPathComponent
                return file.pathExtension == "plist" && domain.hasPrefix("com.cmuxterm.app")
                    && !imported.contains(domain)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                let stored = plist?[key] as? Data
                let former = stored.flatMap { try? JSONDecoder().decode(Former.self, from: $0) }
                // A domain without ranking data is also finished. The daemon records
                // its source with zero rows so a later import never reopens that plist.
                return PaletteUsageLegacyHistory(source: file.deletingPathExtension().lastPathComponent,
                                                 rows: former.map(importRows) ?? [])
            }
    }

    private static func importRows(_ former: Former) -> [JSONValue] {
        former.entries
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty && $0.key.count <= 512
                && $0.value.score.isFinite && $0.value.score > 0 }
            .sorted { $0.key < $1.key }
            .prefix(500)
            .compactMap { key, entry in
                // A time that is not a whole non-negative millisecond count is skipped, not trapped.
                let millisecondsValue = ((entry.lastUsed + Date.timeIntervalBetween1970AndReferenceDate) * 1000).rounded(.down)
                guard let milliseconds = UInt64(exactly: max(0, millisecondsValue)) else { return nil }
                return .object(["key": .string(key), "score": .number(entry.score), "last_used_ms": .string(String(milliseconds))])
            }
    }
}
