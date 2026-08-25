import Foundation

/// Foundation-only view of the workspace color names accepted by config
/// decoding. The app's renderer owns the actual palette values; the CLI needs
/// the same name resolution without importing AppKit.
enum CmuxConfigWorkspaceColorPalette {
    private static let paletteKey = "workspaceTabColor.colors"
    private static let legacyOverridesKey = "workspaceTabColor.defaultOverrides"
    private static let legacyCustomColorsKey = "workspaceTabColor.customColors"
    private static let defaultNames = [
        "Red", "Crimson", "Orange", "Amber", "Olive", "Green", "Teal", "Aqua",
        "Blue", "Navy", "Indigo", "Purple", "Magenta", "Rose", "Brown", "Charcoal",
    ]

    static func containsName(_ rawName: String, defaults: UserDefaults = .standard) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return names(defaults: defaults).contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func names(defaults: UserDefaults) -> [String] {
        if let stored = defaults.dictionary(forKey: paletteKey) as? [String: String] {
            return stored.compactMap { rawName, rawHex in
                guard normalizedHex(rawHex) != nil else { return nil }
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
        }

        var names = defaultNames
        var usedNames = Set(names)
        guard defaults.object(forKey: legacyOverridesKey) != nil
            || defaults.object(forKey: legacyCustomColorsKey) != nil else {
            return names
        }

        var nextCustomIndex = 1
        var seenHexes = Set<String>()
        if let rawColors = defaults.array(forKey: legacyCustomColorsKey) as? [String] {
            for rawColor in rawColors {
                guard let hex = normalizedHex(rawColor), seenHexes.insert(hex).inserted else { continue }
                while usedNames.contains(where: {
                    $0.caseInsensitiveCompare("Custom \(nextCustomIndex)") == .orderedSame
                }) {
                    nextCustomIndex += 1
                }
                let name = "Custom \(nextCustomIndex)"
                names.append(name)
                usedNames.insert(name)
                nextCustomIndex += 1
            }
        }
        return names
    }

    private static func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6, let value = UInt64(body, radix: 16) else { return nil }
        return String(format: "%06llX", value)
    }
}
