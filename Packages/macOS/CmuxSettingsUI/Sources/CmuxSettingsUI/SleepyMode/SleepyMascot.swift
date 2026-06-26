import Foundation

/// Which mascot/face the Sleepy Mode scene draws.
public enum SleepyMascot: String, CaseIterable, Identifiable, Sendable {
    /// The cmux mascot.
    case cmux
    /// A sleepy cat.
    case cat
    /// A friendly ghost.
    case ghost
    /// A face built from the cmux `>` chevron logo.
    case logoFace

    /// Stable identity for `Identifiable` (the raw string value).
    public var id: String { rawValue }
}
