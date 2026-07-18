import Foundation

/// Policy values and normalization helpers for the session content-width cap.
public struct SessionContentWidthSettings: Sendable {
    /// Creates a stateless session content-width policy value.
    public init() {}

    /// The dotted settings path for the active maximum width.
    public static let settingsPath = "terminal.sessionContentMaxWidth"

    /// The dotted settings path for horizontal content placement.
    public static let alignmentSettingsPath = "terminal.sessionContentAlignment"

    /// The `UserDefaults` key that stores the active maximum width.
    public static let maxWidthKey = settingsPath

    /// The `UserDefaults` key that remembers the last enabled maximum width.
    public static let rememberedMaxWidthKey = "terminal.sessionContentMaxWidth.remembered"

    /// The `UserDefaults` key that stores horizontal content placement.
    public static let alignmentKey = alignmentSettingsPath

    /// The stored sentinel value that disables the width cap.
    public static let noMaximumWidth = -1.0

    /// The smallest supported content width, in points.
    public static let minimumWidth = 320.0

    /// The width restored when enabling the cap without a remembered value.
    public static let defaultConfiguredMaximumWidth = 980.0

    /// The increment used by settings controls, in points.
    public static let widthStep = 20.0

    /// Returns the effective maximum width for a stored value.
    ///
    /// - Parameter storedValue: The persisted width value.
    /// - Returns: A normalized width when the cap is enabled, or `nil`.
    public func configuredMaximumWidth(from storedValue: Double) -> Double? {
        guard storedValue.isFinite, storedValue > 0 else { return nil }
        return clampedMaximumWidth(storedValue)
    }

    /// Normalizes a requested maximum width to the supported minimum and step.
    ///
    /// - Parameter value: The requested width in points.
    /// - Returns: A finite width at or above the supported minimum.
    public func clampedMaximumWidth(_ value: Double) -> Double {
        guard value.isFinite else { return Self.defaultConfiguredMaximumWidth }
        let roundedToStep = (value / Self.widthStep).rounded() * Self.widthStep
        guard roundedToStep.isFinite else { return max(Self.minimumWidth, value) }
        return max(Self.minimumWidth, roundedToStep)
    }

    /// Returns the width displayed by the settings editor.
    ///
    /// - Parameters:
    ///   - activeStoredValue: The active persisted width or disabled sentinel.
    ///   - rememberedStoredValue: The last enabled width.
    /// - Returns: The active width when enabled, otherwise the remembered width.
    public func editorMaximumWidth(
        activeStoredValue: Double,
        rememberedStoredValue: Double
    ) -> Double {
        if let active = configuredMaximumWidth(from: activeStoredValue) {
            return active
        }
        return configuredMaximumWidth(from: rememberedStoredValue)
            ?? Self.defaultConfiguredMaximumWidth
    }
}
