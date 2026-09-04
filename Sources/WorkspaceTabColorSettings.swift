import AppKit
import CmuxSettings
import SwiftUI

/// Workspace tab color palette: persistence, legacy migration, palette
/// math, and display-color rendering.
///
/// Fused-enum split status (TabManager decomposition): the storage key is
/// the CmuxSettings catalog's `workspaceColors.palette` entry (sourced below
/// so the wire string is defined once); the pure palette math is **staged
/// for CmuxWorkspaces (Wave 4)**; the `NSColor`/SwiftUI rendering stays
/// app-side until the workspace UI package exists. Moved out of
/// `TabManager.swift` verbatim.
enum WorkspaceTabColorSettings {
    static let paletteKey = CmuxConfigWorkspaceColorPalette.paletteKey

    static var defaultPalette: [WorkspaceTabColorEntry] {
        CmuxConfigWorkspaceColorPalette.defaultPalette.map {
            WorkspaceTabColorEntry(name: $0.name, hex: $0.hex)
        }
    }

    static func palette(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        let paletteMap = CmuxConfigWorkspaceColorPalette.effectivePaletteMap(defaults: defaults)
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

    static func customPaletteEntries(defaults: UserDefaults = .standard) -> [WorkspaceTabColorEntry] {
        let builtInNames = Set(defaultPalette.map(\.name))
        return palette(defaults: defaults).filter { !builtInNames.contains($0.name) }
    }

    static func defaultColorHex(named name: String) -> String? {
        defaultPalette.first(where: { $0.name == name })?.hex
    }

    static func currentColorHex(named name: String, defaults: UserDefaults = .standard) -> String? {
        CmuxConfigWorkspaceColorPalette.effectivePaletteMap(defaults: defaults)[name]
    }

    static func setColor(named name: String, hex: String, defaults: UserDefaults = .standard) {
        guard let normalizedName = normalizedColorName(name),
              let normalizedHex = normalizedHex(hex) else { return }

        var palette = editablePaletteMap(defaults: defaults)
        palette[normalizedName] = normalizedHex
        persistPaletteMap(palette, defaults: defaults)
    }

    static func removeColor(named name: String, defaults: UserDefaults = .standard) {
        guard let normalizedName = normalizedColorName(name) else { return }
        var palette = editablePaletteMap(defaults: defaults)
        palette.removeValue(forKey: normalizedName)
        persistPaletteMap(palette, defaults: defaults)
    }

    static func persistPaletteMap(_ rawPalette: [String: String], defaults: UserDefaults = .standard) {
        let normalizedPalette = normalizedPaletteMap(rawPalette)
        if normalizedPalette == defaultPaletteMap {
            defaults.removeObject(forKey: paletteKey)
        } else {
            defaults.set(normalizedPalette, forKey: paletteKey)
        }
        defaults.removeObject(forKey: CmuxConfigWorkspaceColorPalette.legacyOverridesKey)
        defaults.removeObject(forKey: CmuxConfigWorkspaceColorPalette.legacyCustomColorsKey)
    }

    static func backupPaletteMap(defaults: UserDefaults = .standard) -> [String: String]? {
        if let stored = storedPaletteMap(defaults: defaults) {
            return stored
        }
        return legacyPaletteMap(defaults: defaults)
    }

    static func resolvedPaletteMap(defaults: UserDefaults = .standard) -> [String: String] {
        effectivePaletteMap(defaults: defaults)
    }

    static func addCustomColor(_ hex: String, defaults: UserDefaults = .standard) -> String? {
        guard let normalized = normalizedHex(hex) else { return nil }
        var palette = editablePaletteMap(defaults: defaults)
        if palette.contains(where: { $0.value == normalized }) {
            return normalized
        }

        palette[nextCustomColorName(existingNames: Set(palette.keys))] = normalized
        persistPaletteMap(palette, defaults: defaults)
        return normalized
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: paletteKey)
        defaults.removeObject(forKey: CmuxConfigWorkspaceColorPalette.legacyOverridesKey)
        defaults.removeObject(forKey: CmuxConfigWorkspaceColorPalette.legacyCustomColorsKey)
    }

    static func normalizedHex(_ raw: String) -> String? {
        CmuxConfigWorkspaceColorPalette.normalizedHex(raw)
    }

    /// Compares normalized hex values so persisted formatting cannot hide a match.
    static func paletteEntryMatches(currentHex: String?, entryHex: String) -> Bool {
        guard let currentHex,
              let normalizedCurrent = normalizedHex(currentHex),
              let normalizedEntry = normalizedHex(entryHex) else {
            return false
        }
        return normalizedCurrent == normalizedEntry
    }

    static func displayColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> Color? {
        guard let color = displayNSColor(hex: hex, colorScheme: colorScheme, forceBright: forceBright) else {
            return nil
        }
        return Color(nsColor: color)
    }

    static func displayNSColor(
        hex: String,
        colorScheme: ColorScheme,
        forceBright: Bool = false
    ) -> NSColor? {
        guard let normalized = normalizedHex(hex),
              let baseColor = NSColor(hex: normalized) else {
            return nil
        }

        if forceBright || colorScheme == .dark {
            return brightenedForDarkAppearance(baseColor)
        }
        return baseColor
    }

    private static func effectivePaletteMap(defaults: UserDefaults) -> [String: String] {
        CmuxConfigWorkspaceColorPalette.effectivePaletteMap(defaults: defaults)
    }

    private static func editablePaletteMap(defaults: UserDefaults) -> [String: String] {
        CmuxConfigWorkspaceColorPalette.effectivePaletteMap(defaults: defaults)
    }

    private static func storedPaletteMap(defaults: UserDefaults) -> [String: String]? {
        CmuxConfigWorkspaceColorPalette.storedPaletteMap(defaults: defaults)
    }

    private static func legacyPaletteMap(defaults: UserDefaults) -> [String: String]? {
        CmuxConfigWorkspaceColorPalette.legacyPaletteMap(defaults: defaults)
    }

    private static func normalizedPaletteMap(_ rawPalette: [String: String]) -> [String: String] {
        CmuxConfigWorkspaceColorPalette.normalizedPaletteMap(rawPalette)
    }

    private static var defaultPaletteMap: [String: String] {
        CmuxConfigWorkspaceColorPalette.defaultPaletteMap
    }

    private static func normalizedColorName(_ raw: String) -> String? {
        CmuxConfigWorkspaceColorPalette.normalizedColorName(raw)
    }

    private static func nextCustomColorName(
        existingNames: Set<String>,
        startingAt initialIndex: Int = 1
    ) -> String {
        CmuxConfigWorkspaceColorPalette.nextCustomColorName(
            existingNames: existingNames,
            startingAt: initialIndex
        )
    }

    private static func brightenedForDarkAppearance(_ color: NSColor) -> NSColor {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let boostedBrightness = min(1, max(brightness, 0.62) + ((1 - brightness) * 0.28))
        // Preserve neutral grays when brightening to avoid introducing hue shifts.
        let boostedSaturation: CGFloat
        if saturation <= 0.08 {
            boostedSaturation = saturation
        } else {
            boostedSaturation = min(1, saturation + ((1 - saturation) * 0.12))
        }

        return NSColor(
            hue: hue,
            saturation: boostedSaturation,
            brightness: boostedBrightness,
            alpha: alpha
        )
    }
}
