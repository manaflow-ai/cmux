public import AppKit
public import SwiftUI
import CmuxFoundation
import Foundation

/// The sidebar accent palette and selected-workspace background/foreground
/// colors, plus the small colored-circle swatch image.
///
/// Lifted byte-identically from the app target's `SidebarAppearanceSupport`
/// `cmuxAccent*`/`sidebarActive*`/`sidebarSelected*`/`coloredCircleImage` free
/// functions so the pure palette math lives with the sidebar UI package. The
/// app keeps one-line forwarders into these members as a transitional seam.
/// Pure compute on `NSColor`/`Color`/`NSImage` (with `NSColor(hex:)` from
/// `CmuxFoundation`); no Tab/TabManager/Workspace reach.
public enum SidebarSelectionColors {
    /// The cmux accent blue for the given `colorScheme` (slightly brighter green
    /// channel in dark mode).
    public static func accentNSColor(for colorScheme: ColorScheme) -> NSColor {
        switch colorScheme {
        case .dark:
            return NSColor(
                srgbRed: 0,
                green: 145.0 / 255.0,
                blue: 1.0,
                alpha: 1.0
            )
        default:
            return NSColor(
                srgbRed: 0,
                green: 136.0 / 255.0,
                blue: 1.0,
                alpha: 1.0
            )
        }
    }

    /// The cmux accent blue resolved for an `NSAppearance` (dark/aqua best match).
    public static func accentNSColor(for appAppearance: NSAppearance?) -> NSColor {
        let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
        let scheme: ColorScheme = (bestMatch == .darkAqua) ? .dark : .light
        return accentNSColor(for: scheme)
    }

    /// A dynamic-provider accent `NSColor` that resolves per drawing appearance.
    public static func accentNSColor() -> NSColor {
        NSColor(name: nil) { appearance in
            accentNSColor(for: appearance)
        }
    }

    /// The dynamic accent color as a SwiftUI `Color`.
    public static func accentColor() -> Color {
        Color(nsColor: accentNSColor())
    }

    /// The sidebar's active foreground color (white in dark appearance, black in
    /// light) at the given `opacity` (clamped to `0...1`), resolved against the
    /// supplied app appearance.
    public static func sidebarActiveForegroundNSColor(
        opacity: CGFloat,
        appAppearance: NSAppearance?
    ) -> NSColor {
        let clampedOpacity = max(0, min(opacity, 1))
        let bestMatch = appAppearance?.bestMatch(from: [.darkAqua, .aqua])
        let baseColor: NSColor = (bestMatch == .darkAqua) ? .white : .black
        return baseColor.withAlphaComponent(clampedOpacity)
    }

    /// A 14x14 filled circle swatch in `color`, inset by 1pt.
    public static func coloredCircleImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The selected-workspace background color: the user's custom selection hex
    /// when set and valid, otherwise the accent color for `colorScheme`.
    public static func sidebarSelectedWorkspaceBackgroundNSColor(
        for colorScheme: ColorScheme,
        sidebarSelectionColorHex: String? = UserDefaults.standard.string(forKey: "sidebarSelectionColorHex")
    ) -> NSColor {
        if let hex = sidebarSelectionColorHex,
           let parsed = NSColor(hex: hex) {
            return parsed
        }
        return accentNSColor(for: colorScheme)
    }

    /// The selected-workspace foreground color over the dark-scheme selected
    /// background at the given `opacity`.
    public static func sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
        sidebarSelectedWorkspaceForegroundNSColor(
            on: sidebarSelectedWorkspaceBackgroundNSColor(for: .dark),
            opacity: opacity
        )
    }

    /// The selected-workspace foreground color over `backgroundColor`: white when
    /// white's contrast against the background is below 2.75, otherwise the
    /// readable foreground, at the given `opacity` (clamped to `0...1`).
    public static func sidebarSelectedWorkspaceForegroundNSColor(
        on backgroundColor: NSColor,
        opacity: CGFloat
    ) -> NSColor {
        let clampedOpacity = max(0, min(opacity, 1))
        let whiteContrast = SidebarContrastMath.contrastRatio(foreground: .white, background: backgroundColor)
        guard whiteContrast < 2.75 else {
            return NSColor.white.withAlphaComponent(clampedOpacity)
        }
        return SidebarContrastMath.readableForegroundNSColor(on: backgroundColor, opacity: clampedOpacity)
    }
}
