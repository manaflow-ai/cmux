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
                // Keep the active row legible over terminal output while it
                // remains translucent enough to read as glass. Multi-select
                // rows still reduce this through the shared selection style.
                ?? (colorScheme == .dark ? 0.17 : 0.10)
        )
    }

    static func edge(for colorScheme: ColorScheme, defaults: UserDefaults = .standard) -> NSColor {
        SidebarAppearanceColorResolver().resolvedColor(
            .labelColor,
            for: colorScheme,
            opacity: defaults.object(forKey: "sidebarGlassSelectionEdgeOpacity") as? Double
                // A slightly brighter rim gives the selected row a stable
                // reading edge when the pane is over high-contrast content.
                ?? (colorScheme == .dark ? 0.18 : 0.15)
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
