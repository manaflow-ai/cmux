import Foundation

extension WorkspaceTabColorSettings {
    static func resolvedColorHex(_ raw: String, defaults: UserDefaults = .standard) -> String? {
        resolvedColorHex(raw, palette: resolvedPaletteMap(defaults: defaults))
    }

    /// Same resolution against an already-read palette, so callers resolving a
    /// batch of values read the palette once.
    static func resolvedColorHex(_ raw: String, palette: [String: String]) -> String? {
        if let normalized = normalizedHex(raw) {
            return normalized
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return palette
            .first { name, _ in name.caseInsensitiveCompare(trimmed) == .orderedSame }?
            .value
    }

    static func paletteCacheFingerprint(defaults: UserDefaults = .standard) -> String {
        resolvedPaletteMap(defaults: defaults)
            .sorted { lhs, rhs in lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }
}
