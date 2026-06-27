import Foundation

/// The workspace tab color token palette and pure palette math.
public struct WorkspaceTabColorPalette: Equatable, Sendable {
    /// The built-in workspace color tokens in display order.
    public let builtInEntries: [WorkspaceTabColorEntry]

    /// The built-in workspace tab color palette.
    public static let workspaceTabs = WorkspaceTabColorPalette(
        builtInEntries: [
            WorkspaceTabColorEntry(name: "Red", hex: "#C0392B"),
            WorkspaceTabColorEntry(name: "Crimson", hex: "#922B21"),
            WorkspaceTabColorEntry(name: "Orange", hex: "#A04000"),
            WorkspaceTabColorEntry(name: "Amber", hex: "#7D6608"),
            WorkspaceTabColorEntry(name: "Olive", hex: "#4A5C18"),
            WorkspaceTabColorEntry(name: "Green", hex: "#196F3D"),
            WorkspaceTabColorEntry(name: "Teal", hex: "#006B6B"),
            WorkspaceTabColorEntry(name: "Aqua", hex: "#0E6B8C"),
            WorkspaceTabColorEntry(name: "Blue", hex: "#1565C0"),
            WorkspaceTabColorEntry(name: "Navy", hex: "#1A5276"),
            WorkspaceTabColorEntry(name: "Indigo", hex: "#283593"),
            WorkspaceTabColorEntry(name: "Purple", hex: "#6A1B9A"),
            WorkspaceTabColorEntry(name: "Magenta", hex: "#AD1457"),
            WorkspaceTabColorEntry(name: "Rose", hex: "#880E4F"),
            WorkspaceTabColorEntry(name: "Brown", hex: "#7B3F00"),
            WorkspaceTabColorEntry(name: "Charcoal", hex: "#3E4B5E"),
        ]
    )

    /// Creates a workspace tab color palette.
    ///
    /// - Parameter builtInEntries: The built-in color tokens in display order.
    public init(builtInEntries: [WorkspaceTabColorEntry]) {
        self.builtInEntries = builtInEntries
    }

    /// The built-in palette as a name-to-hex map.
    public var defaultPaletteMap: [String: String] {
        Dictionary(uniqueKeysWithValues: builtInEntries.map { ($0.name, $0.hex) })
    }

    /// Returns the built-in color hex for a palette entry name.
    ///
    /// - Parameter name: The palette entry name.
    /// - Returns: The built-in `#RRGGBB` value, or `nil` when no built-in entry matches.
    public func defaultColorHex(named name: String) -> String? {
        builtInEntries.first(where: { $0.name == name })?.hex
    }

    /// Returns the effective palette map.
    ///
    /// - Parameter stored: The stored palette map, or `nil` to use the built-in palette.
    /// - Returns: A normalized name-to-hex map.
    public func effectivePaletteMap(stored: [String: String]?) -> [String: String] {
        guard let stored else {
            return defaultPaletteMap
        }
        return normalizedPaletteMap(stored)
    }

    /// Returns palette entries in display order.
    ///
    /// Built-in entries retain the built-in order, with overrides applied.
    /// Custom entries follow in localized name order.
    ///
    /// - Parameter stored: The stored palette map, or `nil` to use the built-in palette.
    /// - Returns: The effective ordered palette entries.
    public func entries(stored: [String: String]?) -> [WorkspaceTabColorEntry] {
        let paletteMap = effectivePaletteMap(stored: stored)
        let builtInOrder = builtInEntries.compactMap { entry -> WorkspaceTabColorEntry? in
            guard let hex = paletteMap[entry.name] else { return nil }
            return WorkspaceTabColorEntry(name: entry.name, hex: hex)
        }
        let builtInNames = Set(builtInEntries.map(\.name))
        let customEntries = paletteMap
            .filter { !builtInNames.contains($0.key) }
            .sorted { lhs, rhs in
                lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { WorkspaceTabColorEntry(name: $0.key, hex: $0.value) }
        return builtInOrder + customEntries
    }

    /// Returns only custom palette entries.
    ///
    /// - Parameter stored: The stored palette map, or `nil` to use the built-in palette.
    /// - Returns: Custom entries sorted by name.
    public func customEntries(stored: [String: String]?) -> [WorkspaceTabColorEntry] {
        let builtInNames = Set(builtInEntries.map(\.name))
        return entries(stored: stored).filter { !builtInNames.contains($0.name) }
    }

    /// Returns the current color hex for a palette entry name.
    ///
    /// - Parameters:
    ///   - name: The palette entry name.
    ///   - stored: The stored palette map, or `nil` to use the built-in palette.
    /// - Returns: The effective `#RRGGBB` value, or `nil` when no entry matches.
    public func currentColorHex(named name: String, stored: [String: String]?) -> String? {
        effectivePaletteMap(stored: stored)[name]
    }

    /// Resolves a raw color value to a normalized hex color.
    ///
    /// The raw value may be a direct `#RRGGBB` color or a case-insensitive
    /// palette entry name.
    ///
    /// - Parameters:
    ///   - raw: A direct hex color or palette entry name.
    ///   - stored: The stored palette map, or `nil` to use the built-in palette.
    /// - Returns: A normalized `#RRGGBB` value, or `nil` when the value is invalid.
    public func resolvedColorHex(_ raw: String, stored: [String: String]?) -> String? {
        if let normalized = WorkspaceColorHex(raw)?.rawValue {
            return normalized
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return effectivePaletteMap(stored: stored)
            .first { name, _ in name.caseInsensitiveCompare(trimmed) == .orderedSame }?
            .value
    }

    /// Returns a stable fingerprint for cache invalidation.
    ///
    /// - Parameter stored: The stored palette map, or `nil` to use the built-in palette.
    /// - Returns: A sorted newline-delimited `name=value` fingerprint.
    public func cacheFingerprint(stored: [String: String]?) -> String {
        effectivePaletteMap(stored: stored)
            .sorted { lhs, rhs in lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    /// Returns a normalized palette map by dropping invalid names and colors.
    ///
    /// - Parameter rawPalette: A raw name-to-hex palette map.
    /// - Returns: A normalized name-to-hex map.
    public func normalizedPaletteMap(_ rawPalette: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (rawName, rawHex) in rawPalette {
            guard let name = normalizedColorName(rawName),
                  let hex = WorkspaceColorHex(rawHex)?.rawValue else { continue }
            normalized[name] = hex
        }
        return normalized
    }

    /// Returns a palette map with one named color set.
    ///
    /// - Parameters:
    ///   - name: The raw palette entry name.
    ///   - hex: The raw hex color.
    ///   - stored: The stored palette map, or `nil` to use the built-in palette.
    /// - Returns: The updated palette map, or `nil` when the name or color is invalid.
    public func paletteMapBySettingColor(
        named name: String,
        hex: String,
        stored: [String: String]?
    ) -> [String: String]? {
        guard let normalizedName = normalizedColorName(name),
              let normalizedHex = WorkspaceColorHex(hex)?.rawValue else { return nil }

        var palette = effectivePaletteMap(stored: stored)
        palette[normalizedName] = normalizedHex
        return palette
    }

    /// Returns a palette map with one named color removed.
    ///
    /// - Parameters:
    ///   - name: The raw palette entry name.
    ///   - stored: The stored palette map, or `nil` to use the built-in palette.
    /// - Returns: The updated palette map, or `nil` when the name is invalid.
    public func paletteMapByRemovingColor(
        named name: String,
        stored: [String: String]?
    ) -> [String: String]? {
        guard let normalizedName = normalizedColorName(name) else { return nil }
        var palette = effectivePaletteMap(stored: stored)
        palette.removeValue(forKey: normalizedName)
        return palette
    }

    /// Returns a palette map with a custom color added.
    ///
    /// Duplicate custom hexes return the normalized hex without changing the
    /// supplied palette.
    ///
    /// - Parameters:
    ///   - hex: The raw hex color.
    ///   - stored: The stored palette map, or `nil` to use the built-in palette.
    /// - Returns: The normalized hex and updated palette, or `nil` when the color is invalid.
    public func paletteMapByAddingCustomColor(
        _ hex: String,
        stored: [String: String]?
    ) -> (normalizedHex: String, paletteMap: [String: String])? {
        guard let normalized = WorkspaceColorHex(hex)?.rawValue else { return nil }
        var palette = effectivePaletteMap(stored: stored)
        if palette.contains(where: { $0.value == normalized }) {
            return (normalized, palette)
        }

        palette[nextCustomColorName(existingNames: Set(palette.keys))] = normalized
        return (normalized, palette)
    }

    /// Returns the next available generated custom color name.
    ///
    /// Names use the `Custom N` format and compare existing names
    /// case-insensitively so user-entered variants cannot collide.
    ///
    /// - Parameters:
    ///   - existingNames: Palette entry names that are already in use.
    ///   - initialIndex: The first numeric suffix to try. Values below `1`
    ///     are treated as `1`.
    /// - Returns: The first available generated custom color name.
    public func nextCustomColorName(
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

    private func normalizedColorName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
