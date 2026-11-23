import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The colors a prompt floating over every app draws (a device asking to see or control this Mac, an agent asking to
/// use an app), resolved from the app's theme so a prompt cmux Remote shows (with the app quit too) wears the same
/// theme as the app's own (CmuxNext's `SurfaceRole.prompt`). The app writes it on every theme change
/// (``write(to:)``); cmux Remote reads it each time it shows a prompt (``load(from:)``) and keeps the system's own
/// colors when there is none. Leo, 2026-11-22: "im not sure what was up with the glass on it, and the lack of
/// theming on it too".
public struct PromptTheme: Codable, Hashable, Sendable {
    /// The theme is dark: the prompt draws the dark appearance's glass.
    public var isDark: Bool
    /// The veil over the glass: the theme's glass tint at the prompt role's density (`FloatingGlassStyle.prompt`).
    public var veil: String
    /// The card as it reads with the veil over the theme's own window (the opaque reference the inks fit on).
    public var card: String
    /// Titles and the primary button's fill.
    public var text: String
    /// The question under the title.
    public var secondaryText: String
    /// The quiet note last, and captions.
    public var tertiaryText: String
    /// A failed answer and the quiet Deny.
    public var danger: String
    /// The theme's accent (the agent's glyph).
    public var accent: String

    /// The prompt role's veil density over the glass (CmuxNext `FloatingGlassStyle.prompt`: dark 0.74, light 0.8).
    public static func veilAlpha(isDark: Bool) -> Double { isDark ? 0.74 : 0.8 }

    /// The prompt's colors for `tokens`, each ink fit to read on the card over the theme's window and over the
    /// brightest and the darkest page an app could show under it.
    public init(tokens: ThemeTokens) {
        let veil = tokens.glassTint.withAlpha(Self.veilAlpha(isDark: tokens.isDark))
        let own = veil.composited(over: tokens.windowBackground)
        let pages = [own, veil.composited(over: .white), veil.composited(over: .black), own]
        func fit(_ ink: ThemeRGB, _ minimum: Double) -> ThemeRGB {
            pages.reduce(ink.withAlpha(1)) { ThemeTokens.readable($0, over: $1, minimum: minimum) }
        }
        isDark = tokens.isDark
        self.veil = Self.hex(veil)
        card = Self.hex(own)
        text = Self.hex(fit(tokens.textPrimary, 4.5))
        secondaryText = Self.hex(fit(tokens.textSecondary, 4.5))
        tertiaryText = Self.hex(fit(tokens.textTertiary, 3))
        danger = Self.hex(fit(tokens.danger, 4.5))
        accent = Self.hex(fit(tokens.accent, 3))
    }

    /// Where the app leaves it for cmux Remote: `~/Library/Application Support/cmux/prompt-theme.json`.
    public static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux", isDirectory: true).appendingPathComponent("prompt-theme.json")
    }

    /// Writes it atomically (a reader never sees half a file).
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }

    /// The file's bytes: sorted-key JSON.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// The theme the app last wrote at `url`; nil when there is none or it does not parse (the prompt keeps the
    /// system's colors).
    public static func load(from url: URL?) -> PromptTheme? {
        guard let url, let data = try? Data(contentsOf: url),
              let theme = try? JSONDecoder().decode(PromptTheme.self, from: data),
              [theme.veil, theme.card, theme.text, theme.secondaryText, theme.tertiaryText, theme.danger, theme.accent]
                .allSatisfy({ rgb($0) != nil })
        else { return nil }
        return theme
    }

    /// `#RRGGBBAA`.
    public static func hex(_ color: ThemeRGB) -> String {
        func byte(_ value: Double) -> String {
            let text = String(Int((min(max(value, 0), 1) * 255).rounded()), radix: 16, uppercase: true)
            return text.count == 1 ? "0" + text : text
        }
        return "#" + byte(color.red) + byte(color.green) + byte(color.blue) + byte(color.alpha)
    }

    /// The color of a `#RRGGBBAA` string; nil when it is not one.
    public static func rgb(_ hex: String) -> ThemeRGB? {
        guard hex.count == 9, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return ThemeRGB(hex: value >> 8, alpha: Double(value & 0xFF) / 255)
    }
}

#if canImport(AppKit)
extension PromptTheme {
    /// The appearance the prompt's glass draws in: the theme's light or dark, not the system's.
    @MainActor public var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    /// `hex` as an sRGB NSColor (clear when it does not parse).
    public static func color(_ hex: String) -> NSColor {
        guard let rgb = rgb(hex) else { return .clear }
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: rgb.alpha)
    }
}
#endif
