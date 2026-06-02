import CoreGraphics
import CoreText
import Foundation

/// Persistent + per-panel font size for the markdown viewer.
///
/// The value is the `.markdown-body` font size in points. The web shell renders
/// the body at `baseRenderPointSize` px intrinsically, so the panel applies
/// `pointSize / baseRenderPointSize` as the WKWebView `pageZoom` to scale the
/// whole rendered document (text, code, tables, diagrams, images) the way
/// browser zoom does. Keep `baseRenderPointSize` in sync with the
/// `.markdown-body { font-size: ... }` rule in `Resources/markdown-viewer/shell.html`.
enum MarkdownFontSizeSettings {
    /// UserDefaults / cmux.json key (`markdown.fontSize`).
    static let key = "markdown.fontSize"
    static let defaultPointSize: Double = 15
    static let minimumPointSize: Double = 8
    static let maximumPointSize: Double = 96
    static let stepPointSize: Double = 1
    /// Intrinsic `.markdown-body` font size baked into shell.html, in CSS px.
    static let baseRenderPointSize: Double = 15

    /// Clamps a requested point size into the supported range.
    static func clamp(_ value: Double) -> Double {
        min(max(value, minimumPointSize), maximumPointSize)
    }

    /// The persistent default point size, honoring `markdown.fontSize` from
    /// UserDefaults / cmux.json and falling back to ``defaultPointSize``.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> Double {
        guard let raw = defaults.object(forKey: key) as? NSNumber else {
            return defaultPointSize
        }
        return clamp(raw.doubleValue)
    }

    /// Persists `points` (clamped, rounded to integer points) as the default
    /// `markdown.fontSize` so new viewers start at this size. The Settings UI
    /// stepper and runtime both read the same key.
    static func setDefault(_ points: Double, defaults: UserDefaults = .standard) {
        defaults.set(Int(clamp(points).rounded()), forKey: key)
    }

    /// The WKWebView `pageZoom` factor that renders the body at `pointSize`.
    static func pageZoom(forPointSize pointSize: Double) -> CGFloat {
        CGFloat(clamp(pointSize) / baseRenderPointSize)
    }
}

/// Body prose font for the markdown viewer, chosen from the user's installed
/// fonts (including custom fonts).
///
/// The stored value is a font-family name; an empty string is the System
/// default (the GitHub stack), which clears the inline override. The chosen
/// family is applied as an inline `font-family` on the content element
/// (mirroring the theme injection). Code blocks keep their own monospace stack
/// from `github-markdown.css`.
enum MarkdownFontFamily {
    /// UserDefaults / cmux.json key (`markdown.fontFamily`).
    static let key = "markdown.fontFamily"
    /// Sentinel value for the System default (inherits the GitHub stack).
    static let systemDefault = ""

    /// Normalizes user/config input before persisting or applying it. Newlines
    /// collapse to spaces so a malformed cmux.json value cannot produce invalid
    /// multiline CSS.
    static func normalized(_ family: String) -> String {
        family
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The CSS `font-family` to apply, or `nil` for the System default. The
    /// family name is quoted so multi-word names resolve correctly.
    static func cssValue(for family: String) -> String? {
        let trimmed = normalized(family)
        guard !trimmed.isEmpty else { return nil }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The persistent default font family, honoring `markdown.fontFamily` from
    /// UserDefaults / cmux.json and falling back to the System default.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> String {
        normalized(defaults.string(forKey: key) ?? systemDefault)
    }

    /// Persists `family` as the default `markdown.fontFamily` so new viewers
    /// start with it. An empty family removes the override.
    static func setDefault(_ family: String, defaults: UserDefaults = .standard) {
        let trimmed = normalized(family)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    private static let familyCache = MarkdownFontFamilyCache()

    /// Installed font families available to choose, sorted case-insensitively
    /// and excluding hidden (dot-prefixed) system fonts.
    ///
    /// Loaded off the main thread (font enumeration can take noticeable time on
    /// machines with many installed fonts) and cached, so the typography popover
    /// opens instantly and the list fills in shortly after.
    static func availableFamilies() async -> [String] {
        await familyCache.families()
    }
}

/// Maximum content column width for the markdown viewer.
///
/// The value is applied as CSS pixels to the rendered `.markdown-body`
/// `max-width`. The panel still uses full available width on narrower splits.
enum MarkdownMaxWidthSettings {
    /// UserDefaults / cmux.json key (`markdown.maxWidth`).
    static let key = "markdown.maxWidth"
    static let defaultCSSPixels: Double = 980
    static let minimumCSSPixels: Double = 320
    static let maximumCSSPixels: Double = 2400
    static let stepCSSPixels: Double = 20

    static func clamp(_ value: Double) -> Double {
        min(max(value, minimumCSSPixels), maximumCSSPixels)
    }

    static func resolvedDefault(defaults: UserDefaults = .standard) -> Double {
        guard let raw = defaults.object(forKey: key) as? NSNumber else {
            return defaultCSSPixels
        }
        return clamp(raw.doubleValue)
    }

    static func setDefault(_ pixels: Double, defaults: UserDefaults = .standard) {
        defaults.set(Int(clamp(pixels).rounded()), forKey: key)
    }

    static func resetDefault(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// Loads and caches the installed font-family list off the main thread.
/// `CTFontManagerCopyAvailableFontFamilyNames` is thread-safe, unlike the
/// AppKit `NSFontManager` accessor.
private actor MarkdownFontFamilyCache {
    private var cached: [String]?

    func families() async -> [String] {
        if let cached { return cached }
        let names = await Task.detached(priority: .userInitiated) { () -> [String] in
            let raw = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
            return raw
                .filter { !$0.hasPrefix(".") }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }.value
        cached = names
        return names
    }
}

/// Writes the markdown viewer typography defaults (size, font, and width).
///
/// Writing the keys triggers `UserDefaults.didChangeNotification`, which open
/// viewers observe: those still on the previous default adopt the new one, while
/// individually customized viewers keep their settings. The same path applies a
/// `markdown.*` change from `cmux.json` (the config file store writes the managed
/// values to `UserDefaults.standard`), so `cmux reload-config` refreshes open
/// viewers too.
enum MarkdownTypographyDefaults {
    static func setDefault(
        fontSize: Double,
        fontFamily: String,
        maxContentWidth: Double,
        defaults: UserDefaults = .standard
    ) {
        MarkdownFontSizeSettings.setDefault(fontSize, defaults: defaults)
        MarkdownFontFamily.setDefault(fontFamily, defaults: defaults)
        MarkdownMaxWidthSettings.setDefault(maxContentWidth, defaults: defaults)
    }

    static func resetToBuiltInDefaults(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: MarkdownFontSizeSettings.key)
        MarkdownFontFamily.setDefault(MarkdownFontFamily.systemDefault, defaults: defaults)
        MarkdownMaxWidthSettings.resetDefault(defaults: defaults)
    }
}
