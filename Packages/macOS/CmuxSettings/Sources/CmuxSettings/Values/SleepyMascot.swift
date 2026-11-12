import Foundation

/// Which mascot/face the Sleepy Mode scene draws.
public enum SleepyMascot: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    case cmux
    case cat
    case ghost
    case logoFace
    public var id: String { rawValue }
}
