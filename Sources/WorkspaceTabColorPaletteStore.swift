import AppKit
import CmuxDesignSystem
import CmuxSettings
import Foundation
import SwiftUI

/// UserDefaults-backed workspace tab color palette storage.
struct WorkspaceTabColorPaletteStore {
    let defaults: UserDefaults
    let paletteKey: String

    private static let defaultPaletteKey = WorkspaceColorsCatalogSection().palette.userDefaultsKey

    private let tokens: WorkspaceTabColorPalette
    private let legacyDefaultOverridesKey = "workspaceTabColor.defaultOverrides"
    private let legacyCustomColorsKey = "workspaceTabColor.customColors"

    init(
        defaults: UserDefaults = .standard,
        paletteKey: String = WorkspaceTabColorPaletteStore.defaultPaletteKey,
        tokens: WorkspaceTabColorPalette = .workspaceTabs
    ) {
        self.defaults = defaults
        self.paletteKey = paletteKey
        self.tokens = tokens
    }

    var defaultPalette: [WorkspaceTabColorEntry] {
        tokens.builtInEntries
    }

    func palette() -> [WorkspaceTabColorEntry] {
        tokens.entries(stored: effectiveStoredPaletteMap())
    }

    func customPaletteEntries() -> [WorkspaceTabColorEntry] {
        tokens.customEntries(stored: effectiveStoredPaletteMap())
    }

    func defaultColorHex(named name: String) -> String? {
        tokens.defaultColorHex(named: name)
    }

    func currentColorHex(named name: String) -> String? {
        tokens.currentColorHex(named: name, stored: effectiveStoredPaletteMap())
    }

    func setColor(named name: String, hex: String) {
        guard let palette = tokens.paletteMapBySettingColor(
            named: name,
            hex: hex,
            stored: effectiveStoredPaletteMap()
        ) else { return }
        persistPaletteMap(palette)
    }

    func removeColor(named name: String) {
        guard let palette = tokens.paletteMapByRemovingColor(
            named: name,
            stored: effectiveStoredPaletteMap()
        ) else { return }
        persistPaletteMap(palette)
    }

    func persistPaletteMap(_ rawPalette: [String: String]) {
        let normalizedPalette = tokens.normalizedPaletteMap(rawPalette)
        if normalizedPalette == tokens.defaultPaletteMap {
            defaults.removeObject(forKey: paletteKey)
        } else {
            defaults.set(normalizedPalette, forKey: paletteKey)
        }
        defaults.removeObject(forKey: legacyDefaultOverridesKey)
        defaults.removeObject(forKey: legacyCustomColorsKey)
    }

    func backupPaletteMap() -> [String: String]? {
        if let stored = storedPaletteMap() {
            return stored
        }
        return legacyPaletteMap()
    }

    func resolvedPaletteMap() -> [String: String] {
        tokens.effectivePaletteMap(stored: effectiveStoredPaletteMap())
    }

    func addCustomColor(_ hex: String) -> String? {
        let storedPalette = effectiveStoredPaletteMap()
        let previousPalette = tokens.effectivePaletteMap(stored: storedPalette)
        guard let result = tokens.paletteMapByAddingCustomColor(
            hex,
            stored: storedPalette
        ) else { return nil }

        if result.paletteMap != previousPalette {
            persistPaletteMap(result.paletteMap)
        }
        return result.normalizedHex
    }

    func reset() {
        defaults.removeObject(forKey: paletteKey)
        defaults.removeObject(forKey: legacyDefaultOverridesKey)
        defaults.removeObject(forKey: legacyCustomColorsKey)
    }

    /// Returns the normalized `#RRGGBB` hex for a raw color, or `nil` when invalid.
    ///
    /// This is a pure transform that uses no store state. Callers that only need
    /// normalization should use the static form to avoid allocating a throwaway
    /// store instance.
    static func normalizedHex(_ raw: String) -> String? {
        WorkspaceColorHex(raw)?.rawValue
    }

    func normalizedHex(_ raw: String) -> String? {
        Self.normalizedHex(raw)
    }

    func resolvedColorHex(_ raw: String) -> String? {
        tokens.resolvedColorHex(raw, stored: effectiveStoredPaletteMap())
    }

    func paletteCacheFingerprint() -> String {
        tokens.cacheFingerprint(stored: effectiveStoredPaletteMap())
    }

    func displayColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> Color? {
        guard let color = displayNSColor(hex: hex, colorScheme: colorScheme, forceBright: forceBright) else {
            return nil
        }
        return Color(nsColor: color)
    }

    func displayNSColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> NSColor? {
        WorkspaceColorHex(hex)?.displayNSColor(
            colorScheme: WorkspaceColorScheme(colorScheme),
            forceBright: forceBright
        )
    }

    private func effectiveStoredPaletteMap() -> [String: String]? {
        if let stored = storedPaletteMap() {
            return stored
        }
        return legacyPaletteMap()
    }

    private func storedPaletteMap() -> [String: String]? {
        guard let raw = defaults.dictionary(forKey: paletteKey) as? [String: String] else { return nil }
        return tokens.normalizedPaletteMap(raw)
    }

    private func legacyPaletteMap() -> [String: String]? {
        let hasLegacyOverrides = defaults.object(forKey: legacyDefaultOverridesKey) != nil
        let hasLegacyCustomColors = defaults.object(forKey: legacyCustomColorsKey) != nil
        guard hasLegacyOverrides || hasLegacyCustomColors else { return nil }

        var palette = tokens.defaultPaletteMap

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
                let name = tokens.nextCustomColorName(
                    existingNames: Set(palette.keys),
                    startingAt: index
                )
                palette[name] = normalized
                index += 1
            }
        }

        return palette
    }
}

private extension WorkspaceColorScheme {
    init(_ colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            self = .dark
        default:
            self = .light
        }
    }
}
