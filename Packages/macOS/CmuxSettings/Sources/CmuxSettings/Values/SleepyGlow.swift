import Foundation

/// Background glow gradient behind the Sleepy Mode scene.
public enum SleepyGlow: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    case black
    case midnight
    case cmux
    case aurora
    case sunset
    case ocean
    case custom
    public var id: String { rawValue }
}
