public import Foundation
import CmuxSettings

/// Workspace tab color palette value + persistence: named-color/hex resolution,
/// the built-in palette data, legacy-map migration, and UserDefaults-backed
/// custom-color storage. Pure Foundation value logic with no AppKit/SwiftUI; the
/// `NSColor`/SwiftUI `Color` rendering half stays app-side as an extension on
/// this type (see the app target's `WorkspaceTabColorSettings+Rendering.swift`).
///
/// On-disk format contract: reads and writes the same `workspaceColors.palette`
/// UserDefaults key (sourced from the CmuxSettings catalog so the wire string is
/// defined once) and the same two legacy keys, producing byte-identical persisted
/// maps. Moved from the app target's `WorkspaceTabColorSettings` /
/// `WorkspaceTabColorResolution`.
public struct WorkspaceTabColorSettings {
    /// The UserDefaults key the effective palette persists under, sourced from the
    /// CmuxSettings `workspaceColors.palette` catalog entry.
    public let paletteKey = WorkspaceColorsCatalogSection().palette.userDefaultsKey

    private let legacyDefaultOverridesKey = "workspaceTabColor.defaultOverrides"
    private let legacyCustomColorsKey = "workspaceTabColor.customColors"

    private let originalPRPalette: [WorkspaceTabColorEntry] = [
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

    /// Creates a workspace tab color settings helper.
    public init() {}

    /// The built-in default palette in its canonical display order.
    public var defaultPalette: [WorkspaceTabColorEntry] {
        originalPRPalette
    }

    /// The effective palette (built-ins in canonical order, then custom entries
    /// sorted by name), resolved from `defaults`.
    public func palette(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        let paletteMap = effectivePaletteMap(defaults: defaults)
        let builtInOrder = defaultPalette.compactMap { entry -> WorkspaceTabColorEntry? in
            guard let hex = paletteMap[entry.name] else { return nil }
            return WorkspaceTabColorEntry(name: entry.name, hex: hex)
        }
        let builtInNames = Set(defaultPalette.map(\.name))
        let customEntries = paletteMap
            .filter { !builtInNames.contains($0.key) }
            .sorted { lhs, rhs in
                lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { WorkspaceTabColorEntry(name: $0.key, hex: $0.value) }
        return builtInOrder + customEntries
    }

    /// The custom (non-built-in) entries from the effective palette.
    public func customPaletteEntries(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        let builtInNames = Set(defaultPalette.map(\.name))
        return palette(defaults: defaults).filter { !builtInNames.contains($0.name) }
    }

    /// The built-in default hex for a named color, or `nil` when the name is not
    /// a built-in.
    public func defaultColorHex(named name: String) -> String? {
        defaultPalette.first(where: { $0.name == name })?.hex
    }

    /// The current effective hex for a named color, or `nil` when the name is not
    /// in the effective palette.
    public func currentColorHex(named name: String, defaults: UserDefaults = .standard) -> String? {
        effectivePaletteMap(defaults: defaults)[name]
    }

    /// Sets (or adds) the hex for a named color, persisting the updated palette.
    /// No-ops when the name or hex is invalid.
    public func setColor(named name: String, hex: String, defaults: UserDefaults = .standard) {
        guard let normalizedName = normalizedColorName(name),
              let normalizedHex = normalizedHex(hex) else { return }

        var palette = editablePaletteMap(defaults: defaults)
        palette[normalizedName] = normalizedHex
        persistPaletteMap(palette, defaults: defaults)
    }

    /// Removes a named color from the palette, persisting the result.
    public func removeColor(named name: String, defaults: UserDefaults = .standard) {
        guard let normalizedName = normalizedColorName(name) else { return }
        var palette = editablePaletteMap(defaults: defaults)
        palette.removeValue(forKey: normalizedName)
        persistPaletteMap(palette, defaults: defaults)
    }

    /// Persists `rawPalette` to `defaults`, normalizing entries and removing the
    /// key entirely when the result equals the built-in defaults. Always clears
    /// the two legacy keys.
    public func persistPaletteMap(_ rawPalette: [String: String], defaults: UserDefaults = .standard) {
        let normalizedPalette = normalizedPaletteMap(rawPalette)
        if normalizedPalette == defaultPaletteMap {
            defaults.removeObject(forKey: paletteKey)
        } else {
            defaults.set(normalizedPalette, forKey: paletteKey)
        }
        defaults.removeObject(forKey: legacyDefaultOverridesKey)
        defaults.removeObject(forKey: legacyCustomColorsKey)
    }

    /// The stored palette map (or its legacy migration) for backup, or `nil` when
    /// nothing is stored.
    public func backupPaletteMap(defaults: UserDefaults = .standard) -> [String: String]? {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        return legacyPaletteMap(defaults: defaults)
    }

    /// The effective palette as a name→hex map.
    public func resolvedPaletteMap(defaults: UserDefaults = .standard) -> [String: String] {
        effectivePaletteMap(defaults: defaults)
    }

    /// Adds a custom color by hex, generating a `Custom N` name, and returns the
    /// normalized hex. Returns the existing match without adding a duplicate, or
    /// `nil` for an invalid hex.
    public func addCustomColor(_ hex: String, defaults: UserDefaults = .standard) -> String? {
        guard let normalized = normalizedHex(hex) else { return nil }
        var palette = editablePaletteMap(defaults: defaults)
        if palette.contains(where: { $0.value == normalized }) {
            return normalized
        }

        palette[nextCustomColorName(existingNames: Set(palette.keys))] = normalized
        persistPaletteMap(palette, defaults: defaults)
        return normalized
    }

    /// Resets the palette to built-in defaults by clearing the stored and legacy
    /// keys.
    public func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: paletteKey)
        defaults.removeObject(forKey: legacyDefaultOverridesKey)
        defaults.removeObject(forKey: legacyCustomColorsKey)
    }

    /// Normalizes a hex string to `#RRGGBB` uppercase, or `nil` when it is not a
    /// valid 6-digit hex color.
    public func normalizedHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6 else { return nil }
        guard UInt64(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }

    /// Resolves a raw color string to a normalized hex: a literal hex normalizes
    /// directly, otherwise the value is matched case-insensitively against the
    /// effective palette's color names. Returns `nil` when neither resolves.
    public func resolvedColorHex(_ raw: String, defaults: UserDefaults = .standard) -> String? {
        if let normalized = normalizedHex(raw) {
            return normalized
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return resolvedPaletteMap(defaults: defaults)
            .first { name, _ in name.caseInsensitiveCompare(trimmed) == .orderedSame }?
            .value
    }

    /// A stable fingerprint of the effective palette (sorted `name=hex` lines),
    /// used to invalidate parsed-config caches when the palette changes.
    public func paletteCacheFingerprint(defaults: UserDefaults = .standard) -> String {
        resolvedPaletteMap(defaults: defaults)
            .sorted { lhs, rhs in lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    private func effectivePaletteMap(defaults: UserDefaults) -> [String: String] {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        if let legacy = legacyPaletteMap(defaults: defaults) {
            return legacy
        }
        return defaultPaletteMap
    }

    private func editablePaletteMap(defaults: UserDefaults) -> [String: String] {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        if let legacy = legacyPaletteMap(defaults: defaults) {
            return legacy
        }
        return defaultPaletteMap
    }

    private func storedPaletteMap(defaults: UserDefaults) -> [String: String]? {
        guard let raw = defaults.dictionary(forKey: paletteKey) as? [String: String] else { return nil }
        return normalizedPaletteMap(raw)
    }

    private func legacyPaletteMap(defaults: UserDefaults) -> [String: String]? {
        let hasLegacyOverrides = defaults.object(forKey: legacyDefaultOverridesKey) != nil
        let hasLegacyCustomColors = defaults.object(forKey: legacyCustomColorsKey) != nil
        guard hasLegacyOverrides || hasLegacyCustomColors else { return nil }

        var palette = defaultPaletteMap

        if let rawOverrides = defaults.dictionary(forKey: legacyDefaultOverridesKey) as? [String: String] {
            let validNames = Set(defaultPalette.map(\.name))
            for (name, hex) in rawOverrides {
                guard validNames.contains(name),
                      let normalized = normalizedHex(hex) else { continue }
                palette[name] = normalized
            }
        }

        if let rawCustomColors = defaults.array(forKey: legacyCustomColorsKey) as? [String] {
            var index = 1
            var seenCustomHexes: Set<String> = []
            for rawHex in rawCustomColors {
                guard let normalized = normalizedHex(rawHex),
                      seenCustomHexes.insert(normalized).inserted else { continue }
                let name = nextCustomColorName(
                    existingNames: Set(palette.keys),
                    startingAt: index
                )
                palette[name] = normalized
                index += 1
            }
        }

        return palette
    }

    private func normalizedPaletteMap(_ rawPalette: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (rawName, rawHex) in rawPalette {
            guard let name = normalizedColorName(rawName),
                  let hex = normalizedHex(rawHex) else { continue }
            normalized[name] = hex
        }
        return normalized
    }

    private var defaultPaletteMap: [String: String] {
        Dictionary(uniqueKeysWithValues: defaultPalette.map { ($0.name, $0.hex) })
    }

    private func normalizedColorName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func nextCustomColorName(
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
}
