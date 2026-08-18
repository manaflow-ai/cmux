import Foundation

/// Persistent default and zoom bounds for the built-in plain-text file editor.
enum FilePreviewFontSizeSettings {
    /// UserDefaults / cmux.json key (`fileEditor.fontSize`).
    static let key = "fileEditor.fontSize"
    static let defaultPointSize: Double = 13
    static let minimumPointSize: Double = 8
    static let maximumPointSize: Double = 36
    static let stepPointSize: Double = 1

    /// Clamps a requested point size into the editor's supported zoom range.
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultPointSize }
        return min(max(value, minimumPointSize), maximumPointSize)
    }

    /// Reads the configured default, falling back to the historical 13-point
    /// editor font and clamping malformed or out-of-range values.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> Double {
        guard let raw = defaults.object(forKey: key) as? NSNumber else {
            return defaultPointSize
        }
        return clamp(raw.doubleValue)
    }

    /// Persists a clamped, whole-point default for newly opened editors.
    static func setDefault(_ points: Double, defaults: UserDefaults = .standard) {
        defaults.set(Int(clamp(points).rounded()), forKey: key)
    }
}
