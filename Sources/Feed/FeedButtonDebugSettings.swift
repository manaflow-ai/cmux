#if DEBUG
import AppKit
import SwiftUI

// MARK: - Debug Settings Store
enum FeedButtonDebugSettings {
    static let styleKey = "feed.button.debug.style"
    static let paletteKey = "feed.button.debug.palette"
    static let compactCornerRadiusKey = "feed.button.debug.compactCornerRadius"
    static let mediumCornerRadiusKey = "feed.button.debug.mediumCornerRadius"
    static let compactHorizontalPaddingKey = "feed.button.debug.compactHorizontalPadding"
    static let mediumHorizontalPaddingKey = "feed.button.debug.mediumHorizontalPadding"
    static let compactVerticalPaddingKey = "feed.button.debug.compactVerticalPadding"
    static let mediumVerticalPaddingKey = "feed.button.debug.mediumVerticalPadding"
    static let glassTintOpacityKey = "feed.button.debug.glassTintOpacity"
    static let borderWidthKey = "feed.button.debug.borderWidth"
    static let generationKey = "feed.button.debug.generation"

    private static let defaults = UserDefaults.standard

    static var visualStyle: FeedButtonDebugVisualStyle {
        FeedButtonDebugVisualStyle(
            rawValue: defaults.string(forKey: styleKey) ?? FeedButtonDebugVisualStyle.solid.rawValue
        ) ?? .solid
    }

    static var palettePreset: FeedButtonDebugPalettePreset {
        FeedButtonDebugPalettePreset(
            rawValue: defaults.string(forKey: paletteKey) ?? FeedButtonDebugPalettePreset.system.rawValue
        ) ?? .system
    }

    static var compactCornerRadius: Double {
        double(forKey: compactCornerRadiusKey, defaultValue: 5)
    }

    static var mediumCornerRadius: Double {
        double(forKey: mediumCornerRadiusKey, defaultValue: 6)
    }

    static var compactHorizontalPadding: Double {
        double(forKey: compactHorizontalPaddingKey, defaultValue: 8)
    }

    static var mediumHorizontalPadding: Double {
        double(forKey: mediumHorizontalPaddingKey, defaultValue: 12)
    }

    static var compactVerticalPadding: Double {
        double(forKey: compactVerticalPaddingKey, defaultValue: 4)
    }

    static var mediumVerticalPadding: Double {
        double(forKey: mediumVerticalPaddingKey, defaultValue: 5)
    }

    static var glassTintOpacity: Double {
        double(forKey: glassTintOpacityKey, defaultValue: 0.42)
    }

    static var borderWidth: Double {
        double(forKey: borderWidthKey, defaultValue: 0.9)
    }

    static func color(
        for kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole,
        colorScheme: ColorScheme
    ) -> Color? {
        guard let raw = defaults.string(forKey: colorKey(kind: kind, role: role)),
              let nsColor = NSColor(hex: raw)
        else {
            return palettePreset.color(for: kind, role: role, colorScheme: colorScheme)
        }
        return Color(nsColor: nsColor)
    }

    static func setColor(
        _ color: Color,
        for kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole
    ) {
        defaults.set(NSColor(color).hexString(), forKey: colorKey(kind: kind, role: role))
        bumpGeneration()
    }

    static func defaultColor(
        for kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole,
        colorScheme: ColorScheme
    ) -> Color {
        palettePreset.color(for: kind, role: role, colorScheme: colorScheme)
            ?? fallbackColor(for: kind, role: role, colorScheme: colorScheme)
    }

    static func applyRaycastGlassPreset() {
        apply(.raycastGlass)
    }

    static func applyPalette(_ palette: FeedButtonDebugPalettePreset) {
        defaults.set(palette.rawValue, forKey: paletteKey)
        clearCustomColors()
        bumpGeneration()
    }

    static func apply(_ preset: FeedButtonDebugPreset) {
        defaults.set(preset.style.rawValue, forKey: styleKey)
        defaults.set(preset.compactCornerRadius, forKey: compactCornerRadiusKey)
        defaults.set(preset.mediumCornerRadius, forKey: mediumCornerRadiusKey)
        defaults.set(preset.compactHorizontalPadding, forKey: compactHorizontalPaddingKey)
        defaults.set(preset.mediumHorizontalPadding, forKey: mediumHorizontalPaddingKey)
        defaults.set(preset.compactVerticalPadding, forKey: compactVerticalPaddingKey)
        defaults.set(preset.mediumVerticalPadding, forKey: mediumVerticalPaddingKey)
        defaults.set(preset.glassTintOpacity, forKey: glassTintOpacityKey)
        defaults.set(preset.borderWidth, forKey: borderWidthKey)
        if let palette = preset.palette {
            defaults.set(palette.rawValue, forKey: paletteKey)
            clearCustomColors()
        }
        bumpGeneration()
    }

    static func reset() {
        let keys = [
            styleKey,
            paletteKey,
            compactCornerRadiusKey,
            mediumCornerRadiusKey,
            compactHorizontalPaddingKey,
            mediumHorizontalPaddingKey,
            compactVerticalPaddingKey,
            mediumVerticalPaddingKey,
            glassTintOpacityKey,
            borderWidthKey,
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        clearCustomColors()
        bumpGeneration()
    }

    static func bumpGeneration() {
        defaults.set(defaults.integer(forKey: generationKey) + 1, forKey: generationKey)
    }

    private static func double(forKey key: String, defaultValue: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.double(forKey: key)
    }

    private static func colorKey(kind: FeedButton.Kind, role: FeedButtonDebugColorRole) -> String {
        "feed.button.debug.color.\(kind.rawValue).\(role.rawValue)"
    }

    private static func clearCustomColors() {
        for kind in FeedButton.Kind.allCases {
            for role in [
                FeedButtonDebugColorRole.background,
                .hoverBackground,
                .foreground,
            ] {
                defaults.removeObject(forKey: colorKey(kind: kind, role: role))
            }
        }
    }

    static func fallbackColor(
        for kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole,
        colorScheme: ColorScheme
    ) -> Color {
        Color(nsColor: NSColor(hex: defaultHex(kind: kind, role: role, colorScheme: colorScheme)) ?? .systemBlue)
    }

    private static func defaultHex(
        kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole,
        colorScheme: ColorScheme
    ) -> String {
        switch role {
        case .background:
            switch kind {
            case .ghost: return colorScheme == .dark ? "#1F2933" : "#E7ECF2"
            case .soft: return colorScheme == .dark ? "#3D4148" : "#E5E7EB"
            case .dark: return colorScheme == .dark ? "#1F1F1F" : "#374151"
            case .light: return colorScheme == .dark ? "#F3F4F6" : "#FFFFFF"
            case .primary: return "#3D7AE0"
            case .success: return "#2E9E59"
            case .warning: return colorScheme == .dark ? "#EA894A" : "#B95A00"
            case .destructive: return "#BF3838"
            }
        case .hoverBackground:
            switch kind {
            case .ghost: return colorScheme == .dark ? "#2E3744" : "#F3F4F6"
            case .soft: return colorScheme == .dark ? "#4B515A" : "#EEF0F3"
            case .dark: return colorScheme == .dark ? "#2B2B2B" : "#4B5563"
            case .light: return colorScheme == .dark ? "#FFFFFF" : "#F9FAFB"
            case .primary: return "#478CF2"
            case .success: return "#38B86B"
            case .warning: return colorScheme == .dark ? "#F28C2E" : "#D96C00"
            case .destructive: return "#D94747"
            }
        case .foreground:
            switch kind {
            case .light: return "#111111"
            case .ghost, .soft: return colorScheme == .dark ? "#EDEDED" : "#111827"
            default: return "#FFFFFF"
            }
        }
    }
}

#endif
