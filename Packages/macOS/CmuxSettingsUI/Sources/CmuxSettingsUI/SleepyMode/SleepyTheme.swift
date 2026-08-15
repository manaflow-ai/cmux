import Foundation

/// Color theme for the Sleepy Mode mascot and scene.
public enum SleepyTheme: String, CaseIterable, Identifiable, Sendable {
    /// cmux's signature blue palette.
    case cmux
    /// Soft pink "blossom" palette.
    case blossom
    /// Cool green "mint" palette.
    case mint
    /// Low-saturation grayscale palette.
    case mono
    /// The user's own colors (see the `custom*` fields on `SleepyModeConfig`).
    case custom

    /// Stable identity for `Identifiable` (the raw string value).
    public var id: String { rawValue }
}
