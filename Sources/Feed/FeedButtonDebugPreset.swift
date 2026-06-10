#if DEBUG
import AppKit
import SwiftUI

// MARK: - Style Presets
enum FeedButtonDebugPreset: String, CaseIterable, Identifiable {
    case solidClassic
    case raycastGlass
    case standardLiquidGlass
    case tintedLiquidGlass
    case nativeGlass
    case nativeProminentGlass
    case liquidCapsule
    case frostedOutline
    case haloGlow
    case commandDark
    case commandLight
    case clearGlass
    case compactGlass
    case nativeBlue
    case liquidMono
    case softHalo
    case hairlineGlass
    case minimalFlat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solidClassic:
            return String(localized: "feed.buttonDebug.preset.solidClassic", defaultValue: "Solid Classic")
        case .raycastGlass:
            return String(localized: "feed.buttonDebug.preset.raycastGlass", defaultValue: "Raycast Glass")
        case .standardLiquidGlass:
            return String(localized: "feed.buttonDebug.preset.standardLiquidGlass", defaultValue: "Standard Liquid Glass")
        case .tintedLiquidGlass:
            return String(localized: "feed.buttonDebug.preset.tintedLiquidGlass", defaultValue: "Tinted Liquid Glass")
        case .nativeGlass:
            return String(localized: "feed.buttonDebug.preset.nativeGlass", defaultValue: "Native Glass")
        case .nativeProminentGlass:
            return String(localized: "feed.buttonDebug.preset.nativeProminentGlass", defaultValue: "Prominent Glass")
        case .liquidCapsule:
            return String(localized: "feed.buttonDebug.preset.liquidCapsule", defaultValue: "Liquid Capsule")
        case .frostedOutline:
            return String(localized: "feed.buttonDebug.preset.frostedOutline", defaultValue: "Frosted Outline")
        case .haloGlow:
            return String(localized: "feed.buttonDebug.preset.haloGlow", defaultValue: "Halo Glow")
        case .commandDark:
            return String(localized: "feed.buttonDebug.preset.commandDark", defaultValue: "Command Dark")
        case .commandLight:
            return String(localized: "feed.buttonDebug.preset.commandLight", defaultValue: "Command Light")
        case .clearGlass:
            return String(localized: "feed.buttonDebug.preset.clearGlass", defaultValue: "Clear Glass")
        case .compactGlass:
            return String(localized: "feed.buttonDebug.preset.compactGlass", defaultValue: "Compact Glass")
        case .nativeBlue:
            return String(localized: "feed.buttonDebug.preset.nativeBlue", defaultValue: "Native Blue")
        case .liquidMono:
            return String(localized: "feed.buttonDebug.preset.liquidMono", defaultValue: "Liquid Mono")
        case .softHalo:
            return String(localized: "feed.buttonDebug.preset.softHalo", defaultValue: "Soft Halo")
        case .hairlineGlass:
            return String(localized: "feed.buttonDebug.preset.hairlineGlass", defaultValue: "Hairline Glass")
        case .minimalFlat:
            return String(localized: "feed.buttonDebug.preset.minimalFlat", defaultValue: "Minimal Flat")
        }
    }

    var style: FeedButtonDebugVisualStyle {
        switch self {
        case .solidClassic: return .solid
        case .raycastGlass: return .glass
        case .standardLiquidGlass: return .standardGlass
        case .tintedLiquidGlass: return .standardTintedGlass
        case .nativeGlass: return .nativeGlass
        case .nativeProminentGlass: return .nativeProminentGlass
        case .liquidCapsule: return .liquid
        case .frostedOutline: return .outline
        case .haloGlow: return .halo
        case .commandDark: return .command
        case .commandLight: return .commandLight
        case .clearGlass: return .nativeGlass
        case .compactGlass: return .glass
        case .nativeBlue: return .nativeGlass
        case .liquidMono: return .liquid
        case .softHalo: return .halo
        case .hairlineGlass: return .outline
        case .minimalFlat: return .flat
        }
    }

    var palette: FeedButtonDebugPalettePreset? {
        switch self {
        case .standardLiquidGlass, .tintedLiquidGlass:
            return .system
        case .solidClassic, .raycastGlass, .nativeGlass, .nativeProminentGlass,
             .liquidCapsule, .frostedOutline, .haloGlow, .commandDark, .commandLight,
             .clearGlass, .compactGlass, .nativeBlue, .liquidMono, .softHalo,
             .hairlineGlass, .minimalFlat:
            return nil
        }
    }

    var compactCornerRadius: Double {
        switch self {
        case .solidClassic, .minimalFlat: return 5.0
        case .raycastGlass, .frostedOutline: return 7.0
        case .standardLiquidGlass, .tintedLiquidGlass: return 8.0
        case .nativeGlass: return 9.0
        case .nativeProminentGlass: return 10.0
        case .liquidCapsule: return 12.0
        case .haloGlow, .commandDark, .commandLight: return 8.0
        case .clearGlass, .nativeBlue, .softHalo: return 9.0
        case .compactGlass: return 6.0
        case .liquidMono: return 11.0
        case .hairlineGlass: return 6.0
        }
    }

    var mediumCornerRadius: Double {
        switch self {
        case .solidClassic, .minimalFlat: return 6.0
        case .raycastGlass, .frostedOutline, .commandDark: return 8.0
        case .standardLiquidGlass, .tintedLiquidGlass: return 9.0
        case .nativeGlass: return 10.0
        case .nativeProminentGlass: return 11.0
        case .liquidCapsule: return 14.0
        case .haloGlow: return 9.0
        case .commandLight: return 8.0
        case .clearGlass, .nativeBlue, .softHalo: return 10.0
        case .compactGlass: return 7.0
        case .liquidMono: return 13.0
        case .hairlineGlass: return 7.0
        }
    }

    var compactHorizontalPadding: Double {
        switch self {
        case .minimalFlat: return 7.0
        case .raycastGlass, .frostedOutline, .commandDark: return 9.0
        case .standardLiquidGlass, .tintedLiquidGlass: return 8.0
        case .nativeGlass: return 9.5
        case .nativeProminentGlass: return 10.0
        case .liquidCapsule: return 10.0
        case .haloGlow: return 9.5
        case .commandLight, .clearGlass, .nativeBlue, .softHalo: return 9.5
        case .compactGlass: return 8.0
        case .liquidMono: return 10.5
        case .hairlineGlass: return 8.5
        case .solidClassic: return 8.0
        }
    }

    var mediumHorizontalPadding: Double {
        switch self {
        case .minimalFlat: return 10.0
        case .standardLiquidGlass, .tintedLiquidGlass: return 12.0
        case .nativeGlass: return 13.0
        case .nativeProminentGlass: return 14.0
        case .liquidCapsule: return 15.0
        case .haloGlow: return 13.0
        case .solidClassic, .raycastGlass, .frostedOutline, .commandDark: return 12.0
        case .commandLight: return 12.0
        case .clearGlass, .nativeBlue, .softHalo: return 13.0
        case .compactGlass: return 11.0
        case .liquidMono: return 14.0
        case .hairlineGlass: return 11.0
        }
    }

    var compactVerticalPadding: Double {
        switch self {
        case .minimalFlat: return 3.5
        case .standardLiquidGlass, .tintedLiquidGlass: return 4.0
        case .nativeGlass: return 5.0
        case .nativeProminentGlass: return 5.5
        case .liquidCapsule, .haloGlow: return 5.0
        case .raycastGlass, .frostedOutline, .commandDark: return 4.5
        case .commandLight, .clearGlass, .nativeBlue, .softHalo: return 4.5
        case .compactGlass: return 2.5
        case .liquidMono: return 5.0
        case .hairlineGlass: return 4.0
        case .solidClassic: return 4.0
        }
    }

    var mediumVerticalPadding: Double {
        switch self {
        case .minimalFlat: return 4.5
        case .standardLiquidGlass, .tintedLiquidGlass: return 5.0
        case .nativeGlass: return 6.0
        case .nativeProminentGlass: return 6.5
        case .liquidCapsule: return 6.5
        case .raycastGlass, .haloGlow: return 6.0
        case .frostedOutline, .commandDark: return 5.5
        case .commandLight, .clearGlass, .nativeBlue, .softHalo: return 5.5
        case .compactGlass: return 3.5
        case .liquidMono: return 6.0
        case .hairlineGlass: return 5.0
        case .solidClassic: return 5.0
        }
    }

    var glassTintOpacity: Double {
        switch self {
        case .solidClassic: return 0.42
        case .raycastGlass: return 0.38
        case .standardLiquidGlass: return 0.0
        case .tintedLiquidGlass: return 0.52
        case .nativeGlass: return 0.22
        case .nativeProminentGlass: return 0.46
        case .liquidCapsule: return 0.30
        case .frostedOutline: return 0.18
        case .haloGlow: return 0.34
        case .commandDark: return 0.24
        case .commandLight: return 0.18
        case .clearGlass: return 0.08
        case .compactGlass: return 0.24
        case .nativeBlue: return 0.34
        case .liquidMono: return 0.20
        case .softHalo: return 0.18
        case .hairlineGlass: return 0.10
        case .minimalFlat: return 0.12
        }
    }

    var borderWidth: Double {
        switch self {
        case .solidClassic, .raycastGlass, .commandDark: return 0.8
        case .standardLiquidGlass, .tintedLiquidGlass: return 0.6
        case .nativeGlass: return 0.6
        case .nativeProminentGlass: return 0.7
        case .liquidCapsule: return 0.7
        case .frostedOutline: return 1.2
        case .haloGlow: return 0.9
        case .commandLight: return 0.8
        case .clearGlass, .nativeBlue: return 0.6
        case .compactGlass: return 0.7
        case .liquidMono, .softHalo: return 0.8
        case .hairlineGlass: return 0.7
        case .minimalFlat: return 0.5
        }
    }

}

#endif
