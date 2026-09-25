import Foundation

/// The cadence for cmux's background update checks.
public enum UpdateCheckFrequency: Double, CaseIterable, Sendable, SettingCodable {
    /// Disable background update checks while keeping manual checks available.
    case never = 0
    /// Check for updates about once per hour.
    case hourly = 3600
    /// Check for updates about once per day.
    case daily = 86400
    /// Check for updates about once per week.
    case weekly = 604800
}
