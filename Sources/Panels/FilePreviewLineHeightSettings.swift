import CoreFoundation
import Foundation

/// Persistent paragraph line-height multiplier for the built-in file editor.
struct FilePreviewLineHeightSettings {
    /// Defaults domain used for the line-height override.
    let defaults: UserDefaults

    /// Creates a line-height settings owner backed by the supplied defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
    var resolvedDefault: Double {
        guard let raw = defaults.object(forKey: Self.key) as? NSNumber,
              CFGetTypeID(raw) != CFBooleanGetTypeID() else {
            return Self.defaultMultiplier
        }
        return Self.clamp(raw.doubleValue)
    }

    /// Persists a clamped multiplier rounded to the setting's tenth-point step.
    func setDefault(_ multiplier: Double) {
        let clamped = Self.clamp(multiplier)
        let rounded = (clamped / Self.stepMultiplier).rounded() * Self.stepMultiplier
        defaults.set(rounded, forKey: Self.key)
    }
}
