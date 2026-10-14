import Foundation

/// Color theme for the Sleepy Mode mascot and scene.
public enum SleepyTheme: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    case cmux
    case blossom
    case mint
    case mono
    case custom
    public var id: String { rawValue }
}
