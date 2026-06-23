public import AppKit
public import SwiftUI
import CmuxAppKitSupportUI

/// Resolved chrome colors for a browser panel: the background fill, the
/// readable color scheme for chrome controls, and the omnibar pill fill.
///
/// Construct it from the panel's current `ColorScheme`, the theme background
/// color, and whether the page draws its configured background. The
/// initializer performs the same color math the app-side
/// `resolvedBrowserChrome*` helpers used to, routed through
/// ``CmuxAppKitSupportUI/WindowChromeColorResolver`` for compositing and
/// readable-scheme selection so the math is not duplicated.
///
/// Not `Sendable`: it stores `NSColor` (a non-`Sendable` AppKit class). The
/// type is constructed and read entirely on the main actor inside the browser
/// panel view, so it never crosses an isolation boundary.
public struct BrowserChromeStyle {
    /// The chrome background fill. `.clear` when the page does not draw a background.
    public let backgroundColor: NSColor

    /// The color scheme with the strongest contrast against the chrome background.
    public let colorScheme: ColorScheme

    /// The fill color for the omnibar pill, derived from the chrome background.
    public let omnibarPillBackgroundColor: NSColor

    /// Resolves the chrome colors for a browser panel.
    ///
    /// - Parameters:
    ///   - colorScheme: The environment color scheme the panel renders in.
    ///   - themeBackgroundColor: The current Ghostty theme background color.
    ///   - drawsBackground: Whether the page draws its configured background;
    ///     when `false` the chrome background is `.clear`.
    public init(
        for colorScheme: ColorScheme,
        themeBackgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let backgroundColor = Self.backgroundColor(
            for: colorScheme,
            themeBackgroundColor: themeBackgroundColor,
            drawsBackground: drawsBackground
        )
        let chromeColorScheme = Self.colorScheme(
            for: colorScheme,
            themeBackgroundColor: themeBackgroundColor
        )
        let omnibarPillBackgroundColor = Self.omnibarPillBackgroundColor(
            for: chromeColorScheme,
            themeBackgroundColor: themeBackgroundColor
        )
        self.backgroundColor = backgroundColor
        self.colorScheme = chromeColorScheme
        self.omnibarPillBackgroundColor = omnibarPillBackgroundColor
    }

    private static func backgroundColor(
        for colorScheme: ColorScheme,
        themeBackgroundColor: NSColor,
        drawsBackground: Bool
    ) -> NSColor {
        guard drawsBackground else { return .clear }
        switch colorScheme {
        case .dark, .light:
            return themeBackgroundColor
        @unknown default:
            return themeBackgroundColor
        }
    }

    private static func colorScheme(
        for colorScheme: ColorScheme,
        themeBackgroundColor: NSColor,
        windowBackgroundColor: NSColor = .windowBackgroundColor
    ) -> ColorScheme {
        let resolver = WindowChromeColorResolver()
        let perceivedBackgroundColor = themeBackgroundColor.alphaComponent < 0.999
            ? resolver.compositedColor(themeBackgroundColor, over: windowBackgroundColor)
            : themeBackgroundColor
        return resolver.readableColorScheme(for: perceivedBackgroundColor)
    }

    private static func omnibarPillBackgroundColor(
        for colorScheme: ColorScheme,
        themeBackgroundColor: NSColor
    ) -> NSColor {
        let darkenMix: CGFloat
        switch colorScheme {
        case .light:
            darkenMix = 0.04
        case .dark:
            darkenMix = 0.05
        @unknown default:
            darkenMix = 0.04
        }

        let blendedColor = themeBackgroundColor.blended(withFraction: darkenMix, of: .black) ?? themeBackgroundColor
        return blendedColor.withAlphaComponent(themeBackgroundColor.alphaComponent)
    }
}
