#if DEBUG
import CmuxFeedUI
import Foundation

// App-side localized display labels for the Feed button style playground.
//
// The `FeedButton` primitive, its `FeedButtonDebugStore`, and the backing
// debug enums live in `CmuxFeedUI`. Their human-readable labels stay here
// in the app target: `String(localized:)` must resolve against the app
// bundle (which carries the `feed.buttonDebug.*` translations), so these
// extensions cannot move into the package without silently dropping the
// non-English (Japanese) strings.

extension FeedButtonDebugVisualStyle {
    var label: String {
        switch self {
        case .solid:
            return String(localized: "feed.buttonDebug.style.solid", defaultValue: "Solid")
        case .glass:
            return String(localized: "feed.buttonDebug.style.glass", defaultValue: "Raycast Glass")
        case .standardGlass:
            return String(localized: "feed.buttonDebug.style.standardGlass", defaultValue: "Standard Glass")
        case .standardTintedGlass:
            return String(localized: "feed.buttonDebug.style.standardTintedGlass", defaultValue: "Standard Tinted Glass")
        case .nativeGlass:
            return String(localized: "feed.buttonDebug.style.nativeGlass", defaultValue: "Native Glass")
        case .nativeProminentGlass:
            return String(localized: "feed.buttonDebug.style.nativeProminentGlass", defaultValue: "Prominent Glass")
        case .liquid:
            return String(localized: "feed.buttonDebug.style.liquid", defaultValue: "Liquid")
        case .halo:
            return String(localized: "feed.buttonDebug.style.halo", defaultValue: "Halo")
        case .command:
            return String(localized: "feed.buttonDebug.style.command", defaultValue: "Command")
        case .commandLight:
            return String(localized: "feed.buttonDebug.style.commandLight", defaultValue: "Command Light")
        case .outline:
            return String(localized: "feed.buttonDebug.style.outline", defaultValue: "Outline")
        case .flat:
            return String(localized: "feed.buttonDebug.style.flat", defaultValue: "Flat")
        }
    }
}

extension FeedButtonDebugPalettePreset {
    var label: String {
        switch self {
        case .system:
            return String(localized: "feed.buttonDebug.palette.system", defaultValue: "System")
        case .glassNeutral:
            return String(localized: "feed.buttonDebug.palette.glassNeutral", defaultValue: "Glass Neutral")
        case .graphite:
            return String(localized: "feed.buttonDebug.palette.graphite", defaultValue: "Graphite")
        case .aqua:
            return String(localized: "feed.buttonDebug.palette.aqua", defaultValue: "Aqua")
        case .orchard:
            return String(localized: "feed.buttonDebug.palette.orchard", defaultValue: "Orchard")
        case .ember:
            return String(localized: "feed.buttonDebug.palette.ember", defaultValue: "Ember")
        case .contrast:
            return String(localized: "feed.buttonDebug.palette.contrast", defaultValue: "Contrast")
        }
    }
}

extension FeedButtonDebugPreset {
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
}

extension FeedButton.Kind {
    var debugLabel: String {
        switch self {
        case .ghost:
            return String(localized: "feed.buttonDebug.kind.ghost", defaultValue: "Ghost")
        case .soft:
            return String(localized: "feed.buttonDebug.kind.soft", defaultValue: "Soft")
        case .dark:
            return String(localized: "feed.buttonDebug.kind.dark", defaultValue: "Dark")
        case .light:
            return String(localized: "feed.buttonDebug.kind.light", defaultValue: "Light")
        case .primary:
            return String(localized: "feed.buttonDebug.kind.primary", defaultValue: "Primary")
        case .success:
            return String(localized: "feed.buttonDebug.kind.success", defaultValue: "Success")
        case .warning:
            return String(localized: "feed.buttonDebug.kind.warning", defaultValue: "Warning")
        case .destructive:
            return String(localized: "feed.buttonDebug.kind.destructive", defaultValue: "Destructive")
        }
    }
}
#endif
