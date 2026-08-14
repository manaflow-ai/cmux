import AppKit
import CmuxSettings
import SwiftUI

/// Row-owned color helpers that preserve native semantic variants while
/// deriving selected colors from the row model.
@MainActor
struct SidebarRowPalette {
    let model: SidebarWorkspaceRowModel
    let chromePalette: ChromePalette

    init(
        model: SidebarWorkspaceRowModel,
        chromePalette: ChromePalette? = nil
    ) {
        self.model = model
        self.chromePalette = chromePalette ?? ChromePalette.resolve(
            theme: .default,
            colorScheme: model.colorSchemeIsDark ? .dark : .light
        )
    }

    var colorScheme: ColorScheme { model.colorSchemeIsDark ? .dark : .light }

    var selectedBackground: NSColor {
        if let hex = model.settings.selectionColorHex, let parsed = NSColor(hex: hex) {
            return parsed
        }
        return (chromePalette.surfaceSelected).cmuxNSColor
    }

    func selectedForeground(_ opacity: CGFloat) -> NSColor {
        if model.settings.selectionColorHex == nil {
            return (chromePalette.textOnSelected).cmuxNSColor.withAlphaComponent(opacity)
        }
        return sidebarSelectedWorkspaceForegroundNSColor(on: selectedBackground, opacity: opacity)
    }

    /// Preserves semantic colors, applying opacity lazily in the drawing appearance.
    func semantic(_ color: NSColor, opacity: CGFloat? = nil) -> NSColor {
        guard let opacity else { return color }
        return NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                let candidate = color.withAlphaComponent(opacity)
                resolved = candidate.usingColorSpace(.sRGB) ?? candidate
            }
            return resolved
        }
    }

    var primaryText: NSColor {
        model.isActive ? selectedForeground(1.0) : (chromePalette[.textPrimary]).cmuxNSColor
    }

    func secondary(
        _ selectedOpacity: CGFloat = 0.75,
        inactiveOpacity: CGFloat? = nil
    ) -> NSColor {
        model.isActive
            ? selectedForeground(selectedOpacity)
            : (chromePalette[.textSecondary]).cmuxNSColor.withAlphaComponent(inactiveOpacity ?? 1)
    }

    /// AppKit link foreground that remains legible on selected rows.
    var linkText: NSColor {
        model.isActive ? selectedForeground(1.0) : (chromePalette[.accent]).cmuxNSColor
    }
}
