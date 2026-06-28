public import AppKit
public import SwiftUI

/// Resolved chrome colors for a browser panel: the panel background, the
/// readable color scheme derived from that background, and the omnibar pill
/// background. Construct one via ``resolve(for:themeBackgroundColor:drawsBackground:)``;
/// the individual `resolved*` statics expose each derivation for testing.
public struct BrowserChromeStyle {
    public let backgroundColor: NSColor
    public let colorScheme: ColorScheme
    public let omnibarPillBackgroundColor: NSColor

    public init(
        backgroundColor: NSColor,
        colorScheme: ColorScheme,
        omnibarPillBackgroundColor: NSColor
    ) {
        self.backgroundColor = backgroundColor
        self.colorScheme = colorScheme
        self.omnibarPillBackgroundColor = omnibarPillBackgroundColor
    }

    public static func resolvedBrowserChromeBackgroundColor(
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

    public static func resolvedBrowserChromeColorScheme(
        for colorScheme: ColorScheme,
        themeBackgroundColor: NSColor,
        windowBackgroundColor: NSColor = .windowBackgroundColor
    ) -> ColorScheme {
        let perceivedBackgroundColor = themeBackgroundColor.alphaComponent < 0.999
            ? themeBackgroundColor.composited(over: windowBackgroundColor)
            : themeBackgroundColor
        return perceivedBackgroundColor.readableColorScheme
    }

    public static func resolvedBrowserOmnibarPillBackgroundColor(
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

    public static func resolve(
        for colorScheme: ColorScheme,
        themeBackgroundColor: NSColor,
        drawsBackground: Bool
    ) -> BrowserChromeStyle {
        let backgroundColor = resolvedBrowserChromeBackgroundColor(
            for: colorScheme,
            themeBackgroundColor: themeBackgroundColor,
            drawsBackground: drawsBackground
        )
        let chromeColorScheme = resolvedBrowserChromeColorScheme(
            for: colorScheme,
            themeBackgroundColor: themeBackgroundColor
        )
        let omnibarPillBackgroundColor = resolvedBrowserOmnibarPillBackgroundColor(
            for: chromeColorScheme,
            themeBackgroundColor: themeBackgroundColor
        )
        return BrowserChromeStyle(
            backgroundColor: backgroundColor,
            colorScheme: chromeColorScheme,
            omnibarPillBackgroundColor: omnibarPillBackgroundColor
        )
    }
}
