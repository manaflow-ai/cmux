import AppKit
import SwiftUI

/// The sidebar's glass selection: a neutral translucent patch of the glass
/// with a hairline edge, never the accent colour (Aside-style). Fill and edge
/// strength can be tuned with the `sidebarGlassSelectionFillOpacity` and
/// `sidebarGlassSelectionEdgeOpacity` defaults.
enum SidebarGlassSelection {
    static func fill(for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> NSColor {
        SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: defaults.object(forKey: "sidebarGlassSelectionFillOpacity") as? Double
                ?? (colorScheme == .dark ? 0.13 : 0.07)
        )
    }

    static func edge(for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> NSColor {
        SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: defaults.object(forKey: "sidebarGlassSelectionEdgeOpacity") as? Double
                ?? (colorScheme == .dark ? 0.14 : 0.12)
        )
    }

    /// Text on a translucent selection. The patch is a tint on the pane, not
    /// a surface, so text keeps the pane's own label colour, which the patch's
    /// hue encodes (white patch on dark glass, black patch on light). Nil for
    /// an opaque selection, which picks its foreground by contrast instead.
    static func foreground(on backgroundColor: NSColor, opacity: CGFloat) -> NSColor? {
        guard backgroundColor.alphaComponent < 0.5 else { return nil }
        let brightness = backgroundColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1
        return (brightness > 0.5 ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
    }
}
