import Foundation

/// Persistent paragraph line-height multiplier for the built-in file editor.
enum FilePreviewLineHeightSettings {
    /// UserDefaults / cmux.json key (`fileEditor.lineHeight`).
    static let key = "fileEditor.lineHeight"
    static let defaultMultiplier: Double = 1
    static let minimumMultiplier: Double = 0.5
    static let maximumMultiplier: Double = 3
    static let stepMultiplier: Double = 0.1

    /// Clamps a multiplier into a readable, finite range.
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMultiplier }
        return min(max(value, minimumMultiplier), maximumMultiplier)
    }

    /// Reads the configured multiplier, preserving the natural editor leading
    /// when the setting is absent or invalid.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> Double {
        guard let raw = defaults.object(forKey: key) as? NSNumber else {
            return defaultMultiplier
        }
        return clamp(raw.doubleValue)
    }

    /// Persists a clamped multiplier rounded to the setting's tenth-point step.
    static func setDefault(_ multiplier: Double, defaults: UserDefaults = .standard) {
        let clamped = clamp(multiplier)
        let rounded = (clamped / stepMultiplier).rounded() * stepMultiplier
        defaults.set(rounded, forKey: key)
    }
}
