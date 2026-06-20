import AppKit
import SwiftUI

struct FileExplorerColors {
    let colorScheme: ColorScheme

    var secondaryTextColor: NSColor {
        colorScheme == .dark ? .labelColor.withAlphaComponent(0.76) : .secondaryLabelColor
    }

    var secondaryIconTint: NSColor {
        colorScheme == .dark ? .labelColor.withAlphaComponent(0.68) : .secondaryLabelColor
    }

    func gitUntrackedTextColor(lightFallback: NSColor) -> NSColor {
        colorScheme == .dark ? .labelColor.withAlphaComponent(0.84) : lightFallback
    }

    static func appearance(for colorScheme: ColorScheme, preservingVariantsOf baseAppearance: NSAppearance?) -> NSAppearance? {
        NSAppearance(named: appearanceName(for: colorScheme, preservingVariantsOf: baseAppearance))
    }

    static func appearanceName(for colorScheme: ColorScheme, preservingVariantsOf baseAppearance: NSAppearance?) -> NSAppearance.Name {
        let match = baseAppearance?.bestMatch(from: [
            .accessibilityHighContrastDarkAqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .aqua
        ])
        let preservesHighContrast = match == .accessibilityHighContrastDarkAqua || match == .accessibilityHighContrastAqua
        switch (colorScheme, preservesHighContrast) {
        case (.dark, true): return .accessibilityHighContrastDarkAqua
        case (.dark, false): return .darkAqua
        case (_, true): return .accessibilityHighContrastAqua
        case (_, false): return .aqua
        }
    }
}
