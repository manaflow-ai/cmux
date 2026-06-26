#if DEBUG
import AppKit
import CmuxFoundation
public import SwiftUI

/// DEBUG-only live store backing the Feed button style playground
/// (`FeedButtonStyleDebugView`) and the `FeedButton` render path.
///
/// Replaces the former `FeedButtonDebugSettings` caseless-enum
/// namespace: the persisted `UserDefaults` keys stay as compile-time
/// constants, but every read and write now goes through an injected
/// `UserDefaults` instead of a hardcoded `UserDefaults.standard`
/// singleton. The store is threaded into the view tree through
/// `EnvironmentValues.feedButtonDebugStore`, whose default value is
/// the single composition point that names `.standard`, so the
/// playground and every `FeedButton` share one constructor-injected
/// store.
public struct FeedButtonDebugStore {
    public static let styleKey = "feed.button.debug.style"
    public static let paletteKey = "feed.button.debug.palette"
    public static let compactCornerRadiusKey = "feed.button.debug.compactCornerRadius"
    public static let mediumCornerRadiusKey = "feed.button.debug.mediumCornerRadius"
    public static let compactHorizontalPaddingKey = "feed.button.debug.compactHorizontalPadding"
    public static let mediumHorizontalPaddingKey = "feed.button.debug.mediumHorizontalPadding"
    public static let compactVerticalPaddingKey = "feed.button.debug.compactVerticalPadding"
    public static let mediumVerticalPaddingKey = "feed.button.debug.mediumVerticalPadding"
    public static let glassTintOpacityKey = "feed.button.debug.glassTintOpacity"
    public static let borderWidthKey = "feed.button.debug.borderWidth"
    public static let generationKey = "feed.button.debug.generation"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var visualStyle: FeedButtonDebugVisualStyle {
        FeedButtonDebugVisualStyle(
            rawValue: defaults.string(forKey: Self.styleKey) ?? FeedButtonDebugVisualStyle.solid.rawValue
        ) ?? .solid
    }

    var palettePreset: FeedButtonDebugPalettePreset {
        FeedButtonDebugPalettePreset(
            rawValue: defaults.string(forKey: Self.paletteKey) ?? FeedButtonDebugPalettePreset.system.rawValue
        ) ?? .system
    }

    var compactCornerRadius: Double {
        double(forKey: Self.compactCornerRadiusKey, defaultValue: 5)
    }

    var mediumCornerRadius: Double {
        double(forKey: Self.mediumCornerRadiusKey, defaultValue: 6)
    }

    var compactHorizontalPadding: Double {
        double(forKey: Self.compactHorizontalPaddingKey, defaultValue: 8)
    }

    var mediumHorizontalPadding: Double {
        double(forKey: Self.mediumHorizontalPaddingKey, defaultValue: 12)
    }

    var compactVerticalPadding: Double {
        double(forKey: Self.compactVerticalPaddingKey, defaultValue: 4)
    }

    var mediumVerticalPadding: Double {
        double(forKey: Self.mediumVerticalPaddingKey, defaultValue: 5)
    }

    var glassTintOpacity: Double {
        double(forKey: Self.glassTintOpacityKey, defaultValue: 0.42)
    }

    var borderWidth: Double {
        double(forKey: Self.borderWidthKey, defaultValue: 0.9)
    }

    public func color(
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

    public func setColor(
        _ color: Color,
        for kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole
    ) {
        defaults.set(NSColor(color).hexString(), forKey: colorKey(kind: kind, role: role))
        bumpGeneration()
    }

    public func defaultColor(
        for kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole,
        colorScheme: ColorScheme
    ) -> Color {
        palettePreset.color(for: kind, role: role, colorScheme: colorScheme)
            ?? fallbackColor(for: kind, role: role, colorScheme: colorScheme)
    }

    func applyRaycastGlassPreset() {
        apply(.raycastGlass)
    }

    public func applyPalette(_ palette: FeedButtonDebugPalettePreset) {
        defaults.set(palette.rawValue, forKey: Self.paletteKey)
        clearCustomColors()
        bumpGeneration()
    }

    public func apply(_ preset: FeedButtonDebugPreset) {
        defaults.set(preset.style.rawValue, forKey: Self.styleKey)
        defaults.set(preset.compactCornerRadius, forKey: Self.compactCornerRadiusKey)
        defaults.set(preset.mediumCornerRadius, forKey: Self.mediumCornerRadiusKey)
        defaults.set(preset.compactHorizontalPadding, forKey: Self.compactHorizontalPaddingKey)
        defaults.set(preset.mediumHorizontalPadding, forKey: Self.mediumHorizontalPaddingKey)
        defaults.set(preset.compactVerticalPadding, forKey: Self.compactVerticalPaddingKey)
        defaults.set(preset.mediumVerticalPadding, forKey: Self.mediumVerticalPaddingKey)
        defaults.set(preset.glassTintOpacity, forKey: Self.glassTintOpacityKey)
        defaults.set(preset.borderWidth, forKey: Self.borderWidthKey)
        if let palette = preset.palette {
            defaults.set(palette.rawValue, forKey: Self.paletteKey)
            clearCustomColors()
        }
        bumpGeneration()
    }

    public func reset() {
        let keys = [
            Self.styleKey,
            Self.paletteKey,
            Self.compactCornerRadiusKey,
            Self.mediumCornerRadiusKey,
            Self.compactHorizontalPaddingKey,
            Self.mediumHorizontalPaddingKey,
            Self.compactVerticalPaddingKey,
            Self.mediumVerticalPaddingKey,
            Self.glassTintOpacityKey,
            Self.borderWidthKey,
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        clearCustomColors()
        bumpGeneration()
    }

    public func bumpGeneration() {
        defaults.set(defaults.integer(forKey: Self.generationKey) + 1, forKey: Self.generationKey)
    }

    private func double(forKey key: String, defaultValue: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.double(forKey: key)
    }

    private func colorKey(kind: FeedButton.Kind, role: FeedButtonDebugColorRole) -> String {
        "feed.button.debug.color.\(kind.rawValue).\(role.rawValue)"
    }

    private func clearCustomColors() {
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

    public func fallbackColor(
        for kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole,
        colorScheme: ColorScheme
    ) -> Color {
        Color(nsColor: NSColor(hex: defaultHex(kind: kind, role: role, colorScheme: colorScheme)) ?? .systemBlue)
    }

    private func defaultHex(
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

private struct FeedButtonDebugStoreEnvironmentKey: EnvironmentKey {
    /// Composition point for the DEBUG playground: the one place that
    /// names `UserDefaults.standard`. Override via
    /// `.environment(\.feedButtonDebugStore, …)` to inject a scoped
    /// `UserDefaults(suiteName:)` in tests.
    static let defaultValue = FeedButtonDebugStore(defaults: .standard)
}

extension EnvironmentValues {
    public var feedButtonDebugStore: FeedButtonDebugStore {
        get { self[FeedButtonDebugStoreEnvironmentKey.self] }
        set { self[FeedButtonDebugStoreEnvironmentKey.self] = newValue }
    }
}
#endif
