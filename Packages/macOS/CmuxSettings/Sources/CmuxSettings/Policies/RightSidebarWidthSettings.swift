import Foundation

/// Policy values and normalization helpers for the right sidebar width override.
public struct RightSidebarWidthSettings: Sendable {
    /// Creates a stateless right sidebar width policy value.
    public init() {}

    /// The `cmux.json` key under `sidebar` that stores the right sidebar maximum width.
    public static let jsonKey = "rightMaxWidth"

    /// The dotted settings path for the right sidebar maximum width override.
    public static let settingsPath = "sidebar.rightMaxWidth"

    /// The `UserDefaults` key that stores the active right sidebar maximum width override.
    public static let maxWidthKey = "rightSidebarMaxWidth"

    /// The `UserDefaults` key that remembers the previous right sidebar maximum width override.
    public static let rememberedMaxWidthKey = "rightSidebarRememberedMaxWidth"

    /// The stored sentinel value that means the built-in dynamic width cap is active.
    public static let noOverrideValue = -1.0

    /// The smallest allowed right sidebar width, in points.
    public static let minimumWidth = 276.0

    /// The built-in right sidebar maximum width, in points, used when no override is active.
    public static let builtInMaximumWidth = 1200.0

    /// The width restored when enabling the override without a remembered value.
    public static let defaultConfiguredMaximumWidth = builtInMaximumWidth

    /// The largest width accepted by settings editors and imported `cmux.json` values.
    public static let settingsEditorMaximumWidth = 4096.0

    /// Returns the effective configured maximum width for a stored value.
    ///
    /// - Parameter storedValue: The persisted width override value.
    /// - Returns: A clamped width when the stored value enables the override, or `nil`.
    public func configuredMaximumWidth(from storedValue: Double) -> Double? {
        guard storedValue.isFinite, storedValue > 0 else {
            return nil
        }
        return clampedSettingsEditorMaximumWidth(storedValue)
    }

    /// Clamps a settings-editor width to the supported range.
    ///
    /// - Parameter value: The requested width in points.
    /// - Returns: A finite rounded width within the settings editor bounds.
    public func clampedSettingsEditorMaximumWidth(_ value: Double) -> Double {
        guard value.isFinite else {
            return Self.defaultConfiguredMaximumWidth
        }
        return min(Self.settingsEditorMaximumWidth, max(Self.minimumWidth, value.rounded()))
    }

    /// Returns the remembered width to restore for a persisted value.
    ///
    /// - Parameter storedValue: The stored remembered width.
    /// - Returns: A clamped remembered width, or the default configured width.
    public func rememberedMaximumWidth(from storedValue: Double) -> Double {
        guard let configuredMaximumWidth = configuredMaximumWidth(from: storedValue) else {
            return Self.defaultConfiguredMaximumWidth
        }
        return clampedSettingsEditorMaximumWidth(configuredMaximumWidth)
    }

    /// Returns the width displayed in settings for the active and remembered values.
    ///
    /// - Parameters:
    ///   - activeStoredValue: The currently active stored override value.
    ///   - rememberedStoredValue: The remembered override value used when inactive.
    /// - Returns: The clamped editor width to show.
    public func editorMaximumWidth(activeStoredValue: Double, rememberedStoredValue: Double) -> Double {
        if let configuredMaximumWidth = configuredMaximumWidth(from: activeStoredValue) {
            return clampedSettingsEditorMaximumWidth(configuredMaximumWidth)
        }
        return rememberedMaximumWidth(from: rememberedStoredValue)
    }

    /// Returns the stored value to write when enabling the override.
    ///
    /// - Parameter rememberedStoredValue: The remembered override value.
    /// - Returns: The clamped override width to store as active.
    public func storedMaximumWidthWhenEnabling(rememberedStoredValue: Double) -> Double {
        rememberedMaximumWidth(from: rememberedStoredValue)
    }

    /// Returns the remembered value to preserve before disabling the override.
    ///
    /// - Parameters:
    ///   - activeStoredValue: The currently active stored override value.
    ///   - rememberedStoredValue: The remembered override value used as fallback.
    /// - Returns: The clamped width to store as remembered.
    public func storedRememberedMaximumWidth(activeStoredValue: Double, rememberedStoredValue: Double) -> Double {
        editorMaximumWidth(activeStoredValue: activeStoredValue, rememberedStoredValue: rememberedStoredValue)
    }
}
