#if DEBUG
import AppKit
import CmuxFoundation
public import SwiftUI

/// DEBUG-only named color palette the Feed button style playground can
/// apply across every ``FeedButton/Kind``. The localized ``label`` lives
/// app-side; this package owns the cases, identity, and color resolution.
public enum FeedButtonDebugPalettePreset: String, CaseIterable, Identifiable {
    case system
    case glassNeutral
    case graphite
    case aqua
    case orchard
    case ember
    case contrast

    public var id: String { rawValue }

    public func color(
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
#endif
