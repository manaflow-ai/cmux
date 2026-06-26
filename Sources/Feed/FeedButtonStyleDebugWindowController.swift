#if DEBUG
import AppKit
import CmuxFoundation
import SwiftUI

enum FeedButtonDebugVisualStyle: String, CaseIterable, Identifiable {
    case solid
    case glass
    case standardGlass
    case standardTintedGlass
    case nativeGlass
    case nativeProminentGlass
    case liquid
    case halo
    case command
    case commandLight
    case outline
    case flat

    var id: String { rawValue }

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

enum FeedButtonDebugColorRole: String {
    case background
    case hoverBackground
    case foreground
}

enum FeedButtonDebugPalettePreset: String, CaseIterable, Identifiable {
    case system
    case glassNeutral
    case graphite
    case aqua
    case orchard
    case ember
    case contrast

    var id: String { rawValue }

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

    func color(
        for kind: FeedButton.Kind,
        role: FeedButtonDebugColorRole,
        colorScheme: ColorScheme
    ) -> Color? {
        guard let palette = palette(for: kind, colorScheme: colorScheme) else { return nil }
        let hex: String
        switch role {
        case .background:
            hex = palette.background
        case .hoverBackground:
            hex = palette.hoverBackground
        case .foreground:
            hex = palette.foreground
        }
        return Color(nsColor: NSColor(hex: hex) ?? .systemBlue)
    }

    private func palette(
        for kind: FeedButton.Kind,
        colorScheme: ColorScheme
    ) -> FeedButtonDebugPalette? {
        switch self {
        case .system:
            return nil
        case .glassNeutral:
            return colorScheme == .dark
                ? glassNeutralDarkPalette(for: kind)
                : glassNeutralLightPalette(for: kind)
        case .graphite:
            return colorScheme == .dark
                ? graphiteDarkPalette(for: kind)
                : graphiteLightPalette(for: kind)
        case .aqua:
            return colorScheme == .dark
                ? aquaDarkPalette(for: kind)
                : aquaLightPalette(for: kind)
        case .orchard:
            return colorScheme == .dark
                ? orchardDarkPalette(for: kind)
                : orchardLightPalette(for: kind)
        case .ember:
            return colorScheme == .dark
                ? emberDarkPalette(for: kind)
                : emberLightPalette(for: kind)
        case .contrast:
            return colorScheme == .dark
                ? contrastDarkPalette(for: kind)
                : contrastLightPalette(for: kind)
        }
    }

    private func glassNeutralDarkPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#5F6B78", hoverBackground: "#768391", foreground: "#F8FAFC")
        case .soft: return .init(background: "#4D5560", hoverBackground: "#626C79", foreground: "#F8FAFC")
        case .dark: return .init(background: "#20252C", hoverBackground: "#303741", foreground: "#FFFFFF")
        case .light: return .init(background: "#E8EDF3", hoverBackground: "#FFFFFF", foreground: "#111827")
        case .primary: return .init(background: "#3F7FDB", hoverBackground: "#5794EF", foreground: "#FFFFFF")
        case .success: return .init(background: "#2D9B67", hoverBackground: "#39B97A", foreground: "#FFFFFF")
        case .warning: return .init(background: "#C87638", hoverBackground: "#E28B49", foreground: "#FFFFFF")
        case .destructive: return .init(background: "#B84A55", hoverBackground: "#D45B67", foreground: "#FFFFFF")
        }
    }

    private func glassNeutralLightPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#DDE5ED", hoverBackground: "#EFF3F7", foreground: "#18202A")
        case .soft: return .init(background: "#E7ECF1", hoverBackground: "#F4F7FA", foreground: "#18202A")
        case .dark: return .init(background: "#4A5563", hoverBackground: "#5D6A7A", foreground: "#FFFFFF")
        case .light: return .init(background: "#FFFFFF", hoverBackground: "#F7F9FB", foreground: "#111827")
        case .primary: return .init(background: "#DCEBFF", hoverBackground: "#EAF3FF", foreground: "#123E70")
        case .success: return .init(background: "#DDF3E7", hoverBackground: "#EBFAF1", foreground: "#155636")
        case .warning: return .init(background: "#F6E3CE", hoverBackground: "#FBEEDF", foreground: "#724116")
        case .destructive: return .init(background: "#F4DDE0", hoverBackground: "#FAE9EB", foreground: "#7D202A")
        }
    }

    private func graphiteDarkPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#3E454E", hoverBackground: "#535B66", foreground: "#F3F4F6")
        case .soft: return .init(background: "#323840", hoverBackground: "#454D57", foreground: "#F8FAFC")
        case .dark: return .init(background: "#14171B", hoverBackground: "#242932", foreground: "#FFFFFF")
        case .light: return .init(background: "#E7EAEE", hoverBackground: "#FFFFFF", foreground: "#111827")
        case .primary: return .init(background: "#596C89", hoverBackground: "#6F829F", foreground: "#FFFFFF")
        case .success: return .init(background: "#5C7669", hoverBackground: "#708C7E", foreground: "#FFFFFF")
        case .warning: return .init(background: "#806D58", hoverBackground: "#97816A", foreground: "#FFFFFF")
        case .destructive: return .init(background: "#806064", hoverBackground: "#967276", foreground: "#FFFFFF")
        }
    }

    private func graphiteLightPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#E2E5E9", hoverBackground: "#F0F2F4", foreground: "#151A20")
        case .soft: return .init(background: "#D7DCE2", hoverBackground: "#E7EAEE", foreground: "#151A20")
        case .dark: return .init(background: "#3A414B", hoverBackground: "#4C5561", foreground: "#FFFFFF")
        case .light: return .init(background: "#FFFFFF", hoverBackground: "#F6F7F9", foreground: "#111827")
        case .primary: return .init(background: "#DCE3ED", hoverBackground: "#E8EEF5", foreground: "#26374E")
        case .success: return .init(background: "#DDE8E2", hoverBackground: "#EAF2EE", foreground: "#294638")
        case .warning: return .init(background: "#EBE1D4", hoverBackground: "#F4EBE1", foreground: "#57402A")
        case .destructive: return .init(background: "#EBDADC", hoverBackground: "#F4E6E8", foreground: "#613238")
        }
    }

    private func aquaDarkPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#315E73", hoverBackground: "#417A94", foreground: "#EAFBFF")
        case .soft: return .init(background: "#294B5A", hoverBackground: "#386578", foreground: "#EAFBFF")
        case .dark: return .init(background: "#10202A", hoverBackground: "#1C3542", foreground: "#FFFFFF")
        case .light: return .init(background: "#DDF4FA", hoverBackground: "#F0FCFF", foreground: "#0E2E3A")
        case .primary: return .init(background: "#2477D6", hoverBackground: "#3490F4", foreground: "#FFFFFF")
        case .success: return .init(background: "#159B86", hoverBackground: "#20BBA2", foreground: "#FFFFFF")
        case .warning: return .init(background: "#C88A31", hoverBackground: "#E6A043", foreground: "#FFFFFF")
        case .destructive: return .init(background: "#C74C67", hoverBackground: "#E15F7B", foreground: "#FFFFFF")
        }
    }

    private func aquaLightPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#D8EEF5", hoverBackground: "#EAF8FC", foreground: "#103544")
        case .soft: return .init(background: "#E1F2F6", hoverBackground: "#F0FAFC", foreground: "#103544")
        case .dark: return .init(background: "#2D5363", hoverBackground: "#3C6A7D", foreground: "#FFFFFF")
        case .light: return .init(background: "#FFFFFF", hoverBackground: "#F3FBFD", foreground: "#102A35")
        case .primary: return .init(background: "#D7EBFF", hoverBackground: "#E6F4FF", foreground: "#0B3E6F")
        case .success: return .init(background: "#D8F3EE", hoverBackground: "#E8FAF6", foreground: "#0F554B")
        case .warning: return .init(background: "#F5E7CF", hoverBackground: "#FBF0DE", foreground: "#6A4517")
        case .destructive: return .init(background: "#F3DDE5", hoverBackground: "#FAE9EF", foreground: "#76233A")
        }
    }

    private func orchardDarkPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#496B58", hoverBackground: "#5C846D", foreground: "#F0FFF6")
        case .soft: return .init(background: "#3F5849", hoverBackground: "#526E5D", foreground: "#F0FFF6")
        case .dark: return .init(background: "#17251C", hoverBackground: "#24372B", foreground: "#FFFFFF")
        case .light: return .init(background: "#E6F2EA", hoverBackground: "#F7FCF8", foreground: "#132519")
        case .primary: return .init(background: "#3E7FD8", hoverBackground: "#5595EF", foreground: "#FFFFFF")
        case .success: return .init(background: "#289A55", hoverBackground: "#35B868", foreground: "#FFFFFF")
        case .warning: return .init(background: "#B4832E", hoverBackground: "#CE9A40", foreground: "#FFFFFF")
        case .destructive: return .init(background: "#B84D4D", hoverBackground: "#D25E5E", foreground: "#FFFFFF")
        }
    }

    private func orchardLightPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#DDEDE4", hoverBackground: "#EDF7F0", foreground: "#183323")
        case .soft: return .init(background: "#E5F1E9", hoverBackground: "#F2F8F4", foreground: "#183323")
        case .dark: return .init(background: "#40584A", hoverBackground: "#536D5C", foreground: "#FFFFFF")
        case .light: return .init(background: "#FFFFFF", hoverBackground: "#F6FAF7", foreground: "#132519")
        case .primary: return .init(background: "#DDEBFF", hoverBackground: "#EAF3FF", foreground: "#143E70")
        case .success: return .init(background: "#DDF3E5", hoverBackground: "#EAFAF0", foreground: "#145431")
        case .warning: return .init(background: "#F2E6CE", hoverBackground: "#F9F0DE", foreground: "#604512")
        case .destructive: return .init(background: "#F1DDDD", hoverBackground: "#F9EAEA", foreground: "#762626")
        }
    }

    private func emberDarkPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#77543F", hoverBackground: "#926950", foreground: "#FFF7F0")
        case .soft: return .init(background: "#654738", hoverBackground: "#7C5947", foreground: "#FFF7F0")
        case .dark: return .init(background: "#281B16", hoverBackground: "#3A2922", foreground: "#FFFFFF")
        case .light: return .init(background: "#F4E7DC", hoverBackground: "#FFF6EF", foreground: "#2A1710")
        case .primary: return .init(background: "#306FD1", hoverBackground: "#4388EF", foreground: "#FFFFFF")
        case .success: return .init(background: "#398D61", hoverBackground: "#49AA77", foreground: "#FFFFFF")
        case .warning: return .init(background: "#D7782C", hoverBackground: "#EF8E3F", foreground: "#FFFFFF")
        case .destructive: return .init(background: "#BE4441", hoverBackground: "#D95753", foreground: "#FFFFFF")
        }
    }

    private func emberLightPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#F0E2D7", hoverBackground: "#F8ECE3", foreground: "#3C2419")
        case .soft: return .init(background: "#E9D9CD", hoverBackground: "#F3E6DD", foreground: "#3C2419")
        case .dark: return .init(background: "#684B3D", hoverBackground: "#7D5D4E", foreground: "#FFFFFF")
        case .light: return .init(background: "#FFFFFF", hoverBackground: "#FAF5F0", foreground: "#2A1710")
        case .primary: return .init(background: "#DCEAFF", hoverBackground: "#EAF3FF", foreground: "#153D70")
        case .success: return .init(background: "#E1F0E6", hoverBackground: "#ECF8F0", foreground: "#255538")
        case .warning: return .init(background: "#F8E1CA", hoverBackground: "#FCECDD", foreground: "#6C3A12")
        case .destructive: return .init(background: "#F3DAD8", hoverBackground: "#FAE8E6", foreground: "#79211F")
        }
    }

    private func contrastDarkPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#4B5563", hoverBackground: "#64748B", foreground: "#FFFFFF")
        case .soft: return .init(background: "#374151", hoverBackground: "#4B5563", foreground: "#FFFFFF")
        case .dark: return .init(background: "#030712", hoverBackground: "#111827", foreground: "#FFFFFF")
        case .light: return .init(background: "#FFFFFF", hoverBackground: "#E5E7EB", foreground: "#030712")
        case .primary: return .init(background: "#0069E6", hoverBackground: "#1D83FF", foreground: "#FFFFFF")
        case .success: return .init(background: "#008F55", hoverBackground: "#00AA66", foreground: "#FFFFFF")
        case .warning: return .init(background: "#B95A00", hoverBackground: "#D96C00", foreground: "#FFFFFF")
        case .destructive: return .init(background: "#C51F32", hoverBackground: "#E2384C", foreground: "#FFFFFF")
        }
    }

    private func contrastLightPalette(for kind: FeedButton.Kind) -> FeedButtonDebugPalette {
        switch kind {
        case .ghost: return .init(background: "#E5E7EB", hoverBackground: "#F3F4F6", foreground: "#030712")
        case .soft: return .init(background: "#D1D5DB", hoverBackground: "#E5E7EB", foreground: "#030712")
        case .dark: return .init(background: "#111827", hoverBackground: "#1F2937", foreground: "#FFFFFF")
        case .light: return .init(background: "#FFFFFF", hoverBackground: "#F9FAFB", foreground: "#030712")
        case .primary: return .init(background: "#005FD1", hoverBackground: "#0074F5", foreground: "#FFFFFF")
        case .success: return .init(background: "#007F4B", hoverBackground: "#00995B", foreground: "#FFFFFF")
        case .warning: return .init(background: "#A84F00", hoverBackground: "#C46100", foreground: "#FFFFFF")
        case .destructive: return .init(background: "#B91C2D", hoverBackground: "#D42D40", foreground: "#FFFFFF")
        }
    }
}

struct FeedButtonDebugPalette {
    let background: String
    let hoverBackground: String
    let foreground: String
}

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

extension FeedButton.Kind: CaseIterable, Identifiable {
    static var allCases: [FeedButton.Kind] {
        [.ghost, .soft, .dark, .light, .primary, .success, .warning, .destructive]
    }

    var id: String { rawValue }

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

final class FeedButtonStyleDebugWindowController: ReleasingWindowController {
    static let shared = FeedButtonStyleDebugWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "feed.buttonDebug.windowTitle",
            defaultValue: "Feed Button Style"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.feedButtonStyleDebug")
        window.minSize = NSSize(width: 460, height: 520)
        window.center()
        window.contentView = NSHostingView(rootView: FeedButtonStyleDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        showManagedWindow()
    }
}
#endif
