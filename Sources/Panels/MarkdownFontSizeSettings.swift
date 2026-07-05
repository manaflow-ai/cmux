import CoreGraphics
import Foundation

/// Persistent + per-panel font size for the markdown viewer.
///
/// The value is the `.markdown-body` font size in points. The web shell renders
/// the body at `baseRenderPointSize` px intrinsically, so the panel applies
/// `pointSize / baseRenderPointSize` as the WKWebView `pageZoom` to scale the
/// rendered document the way browser zoom does. Mermaid SVGs also receive this
/// factor in the shell because Mermaid emits inline max-width values that
/// WebKit text zoom does not resize. Keep `baseRenderPointSize` in sync with
/// the `.markdown-body { font-size: ... }` rule in `Resources/markdown-viewer/shell.html`.
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
