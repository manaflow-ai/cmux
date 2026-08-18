import CoreFoundation
import Foundation

/// Persistent default and zoom bounds for the built-in plain-text file editor.
struct FilePreviewFontSizeSettings {
    /// Defaults domain used for the size override.
    let defaults: UserDefaults

    /// Creates a font-size settings owner backed by the supplied defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
    var resolvedDefault: Double {
        guard let raw = defaults.object(forKey: Self.key) as? NSNumber,
              CFGetTypeID(raw) != CFBooleanGetTypeID() else {
            return Self.defaultPointSize
        }
        return Self.clamp(raw.doubleValue)
    }

    /// Persists a clamped, whole-point default for newly opened editors.
    func setDefault(_ points: Double) {
        defaults.set(Int(Self.clamp(points).rounded()), forKey: Self.key)
    }
}
