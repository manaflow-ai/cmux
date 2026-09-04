import Foundation

/// Foundation-only workspace palette storage and resolution.
///
/// The app renderer and the CLI validator both consume this declaration. It is
/// deliberately free of AppKit so legacy settings, custom names, and hex
/// normalization cannot drift between config validation and runtime decoding.
nonisolated enum CmuxConfigWorkspaceColorPalette {
    nonisolated struct Entry: Equatable, Sendable {
        let name: String
        let hex: String
    }

    static let paletteKey = "workspaceTabColor.colors"
    static let legacyOverridesKey = "workspaceTabColor.defaultOverrides"
    static let legacyCustomColorsKey = "workspaceTabColor.customColors"

    static let defaultPalette: [Entry] = [
        Entry(name: "Red", hex: "#C0392B"),
        Entry(name: "Crimson", hex: "#922B21"),
        Entry(name: "Orange", hex: "#A04000"),
        Entry(name: "Amber", hex: "#7D6608"),
        Entry(name: "Olive", hex: "#4A5C18"),
        Entry(name: "Green", hex: "#196F3D"),
        Entry(name: "Teal", hex: "#006B6B"),
        Entry(name: "Aqua", hex: "#0E6B8C"),
        Entry(name: "Blue", hex: "#1565C0"),
        Entry(name: "Navy", hex: "#1A5276"),
        Entry(name: "Indigo", hex: "#283593"),
        Entry(name: "Purple", hex: "#6A1B9A"),
        Entry(name: "Magenta", hex: "#AD1457"),
        Entry(name: "Rose", hex: "#880E4F"),
        Entry(name: "Brown", hex: "#7B3F00"),
        Entry(name: "Charcoal", hex: "#3E4B5E"),
    ]

    static func containsName(_ rawName: String, defaults: UserDefaults = .standard) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return effectivePaletteMap(defaults: defaults).keys.contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    static func resolvedColorHex(_ raw: String, defaults: UserDefaults = .standard) -> String? {
        if let normalized = normalizedHex(raw) {
            return normalized
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let palette = effectivePaletteMap(defaults: defaults)
        if let exact = palette[trimmed] {
            return exact
        }
        return palette
            .filter { $0.key.caseInsensitiveCompare(trimmed) == .orderedSame }
            .min { $0.key < $1.key }?
            .value
    }

    static func effectivePaletteMap(defaults: UserDefaults = .standard) -> [String: String] {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        if let legacy = legacyPaletteMap(defaults: defaults) {
            return legacy
        }
        return defaultPaletteMap
    }

    static func storedPaletteMap(defaults: UserDefaults = .standard) -> [String: String]? {
        guard let raw = defaults.dictionary(forKey: paletteKey) as? [String: String] else { return nil }
        return normalizedPaletteMap(raw)
    }

    static func legacyPaletteMap(defaults: UserDefaults = .standard) -> [String: String]? {
        let hasLegacyOverrides = defaults.object(forKey: legacyOverridesKey) != nil
        let hasLegacyCustomColors = defaults.object(forKey: legacyCustomColorsKey) != nil
        guard hasLegacyOverrides || hasLegacyCustomColors else { return nil }

        var palette = defaultPaletteMap
        if let rawOverrides = defaults.dictionary(forKey: legacyOverridesKey) as? [String: String] {
            let validNames = Set(defaultPalette.map(\.name))
            for (name, hex) in rawOverrides {
                guard validNames.contains(name), let normalized = normalizedHex(hex) else { continue }
                palette[name] = normalized
            }
        }

        if let rawCustomColors = defaults.array(forKey: legacyCustomColorsKey) as? [String] {
            var index = 1
            var seenCustomHexes = Set<String>()
            for rawHex in rawCustomColors {
                guard let normalized = normalizedHex(rawHex), seenCustomHexes.insert(normalized).inserted else {
                    continue
                }
                let name = nextCustomColorName(existingNames: Set(palette.keys), startingAt: index)
                palette[name] = normalized
                index += 1
            }
        }
        return palette
    }

    static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard body.count == 6,
              body.unicodeScalars.allSatisfy({ hexDigits.contains($0) }),
              UInt64(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }

    static func normalizedPaletteMap(_ rawPalette: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (rawName, rawHex) in rawPalette {
            guard let name = normalizedColorName(rawName), let hex = normalizedHex(rawHex) else { continue }
            normalized[name] = hex
        }
        return normalized
    }

    static func normalizedColorName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func nextCustomColorName(
        existingNames: Set<String>,
        startingAt initialIndex: Int = 1
    ) -> String {
        var index = max(1, initialIndex)
        while true {
            let candidate = "Custom \(index)"
            if !existingNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return candidate
            }
            index += 1
        }
    }

    static var defaultPaletteMap: [String: String] {
        Dictionary(uniqueKeysWithValues: defaultPalette.map { ($0.name, $0.hex) })
    }
}
