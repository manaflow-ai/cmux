import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Browser Chrome Style
struct OmnibarAddressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OmnibarAddressButtonStyleBody(configuration: configuration)
    }
}

private struct OmnibarAddressButtonStyleBody: View {
    let configuration: OmnibarAddressButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension View {
    func cmuxFlatSymbolColorRendering() -> some View {
        // `symbolColorRenderingMode(.flat)` is not available in the current SDK
        // used by CI/local builds. Keep this modifier as a compatibility no-op.
        self
    }
}

func resolvedBrowserChromeBackgroundColor(
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

func resolvedBrowserChromeColorScheme(
    for colorScheme: ColorScheme,
    themeBackgroundColor: NSColor,
    windowBackgroundColor: NSColor = .windowBackgroundColor
) -> ColorScheme {
    let perceivedBackgroundColor = themeBackgroundColor.alphaComponent < 0.999
        ? cmuxCompositedNSColor(themeBackgroundColor, over: windowBackgroundColor)
        : themeBackgroundColor
    return cmuxReadableColorScheme(for: perceivedBackgroundColor)
}

func resolvedBrowserOmnibarPillBackgroundColor(
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

struct BrowserChromeStyle {
    let backgroundColor: NSColor
    let colorScheme: ColorScheme
    let omnibarPillBackgroundColor: NSColor

    static func resolve(
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

