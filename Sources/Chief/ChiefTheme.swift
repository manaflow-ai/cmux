import AppKit
import CmuxHomeRender

/// Chief's colours from the terminal theme: the transcript takes Ghostty's
/// default background and foreground, the sent bubble is iMessage blue on
/// every theme (MessagesLab's measured blue, `measuredAccent`), and the
/// chrome around it (first run, settings panel, list) mixes the two.
struct ChiefTheme: Equatable {
    /// MessagesLab's measured sent-bubble blue.
    static let messagesBlue = NSColor(srgbRed: 2 / 255, green: 132 / 255, blue: 254 / 255, alpha: 1)

    /// The terminal's background, with its opacity.
    var background: NSColor
    /// The terminal's background, opaque.
    var opaqueBackground: NSColor
    var foreground: NSColor

    /// The current terminal theme.
    static func current() -> ChiefTheme {
        let app = GhosttyApp.shared
        let background = GhosttyBackgroundTheme.currentColor()
        return ChiefTheme(background: background,
                          opaqueBackground: app.defaultBackgroundColor.withAlphaComponent(1),
                          foreground: app.defaultForegroundColor.withAlphaComponent(1))
    }

    /// Whether the background reads as dark.
    var isDark: Bool {
        let c = opaqueBackground.usingColorSpace(.sRGB) ?? opaqueBackground
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }

    /// The AppKit appearance for everything Chief draws in the content area
    /// (transcript, header pill, buttons, chips, settings panel, memory sheet),
    /// so system controls and dynamic colors resolve in the same light or dark
    /// as the Ghostty-derived palette rather than in the app's appearance.
    ///
    /// Convention: content-area surfaces follow the terminal theme, as the
    /// Markdown panel (`MarkdownWebTheme`) and in-app dialogs
    /// (`GhosttyDialogTheme`) do; the left sidebar, Chief's conversation list
    /// included, follows the sidebar's appearance like the workspace rows.
    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    /// `fraction` of the foreground over the opaque background.
    func mix(_ fraction: CGFloat) -> NSColor {
        opaqueBackground.blended(withFraction: fraction, of: foreground) ?? opaqueBackground
    }

    var textPrimary: NSColor { foreground }
    var textSecondary: NSColor { foreground.withAlphaComponent(0.62) }
    var textTertiary: NSColor { foreground.withAlphaComponent(0.45) }
    /// A raised control fill (first-run rows).
    var raisedFill: NSColor { mix(isDark ? 0.07 : 0.035) }
    var hoverFill: NSColor { mix(isDark ? 0.12 : 0.07) }
    var hairline: NSColor { foreground.withAlphaComponent(isDark ? 0.12 : 0.1) }
    /// A panel set apart from the transcript (the settings panel).
    var panelFill: NSColor { mix(isDark ? 0.05 : 0.03) }
    var danger: NSColor { .systemRed }

    /// The transcript's palettes for the key and non-key window.
    func palettes() -> (active: HomePalette, inactive: HomePalette) {
        let theme = HomePalette.Theme(background: Self.homeColor(opaqueBackground, keepAlpha: false),
                                      foreground: Self.homeColor(foreground, keepAlpha: false),
                                      accent: Self.homeColor(Self.messagesBlue, keepAlpha: false),
                                      failure: Self.homeColor(.systemRed, keepAlpha: false))
        var active = HomePalette.themed(theme, active: true)
        var inactive = HomePalette.themed(theme, active: false)
        // The pane paints the terminal's own background (its opacity included), never a tint of its own.
        active.background = Self.homeColor(background, keepAlpha: true)
        inactive.background = active.background
        return (active, inactive)
    }

    static func homeColor(_ color: NSColor, keepAlpha: Bool) -> HomeColor {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        return HomeColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent,
                         alpha: keepAlpha ? c.alphaComponent : 1)
    }
}
