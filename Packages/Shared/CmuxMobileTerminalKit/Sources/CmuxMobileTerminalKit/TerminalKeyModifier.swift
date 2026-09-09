import Foundation

/// Platform-neutral terminal input modifier flags.
///
/// Mirrors the subset of `UIKeyModifierFlags` the terminal input pipeline
/// cares about (`shift`, `control`, `alternate`) without forcing this layer
/// to depend on UIKit, so the byte-encoding tables stay testable on any
/// platform. The UI host translates `UIKeyModifierFlags` into this type at the
/// seam.
public struct TerminalKeyModifier: OptionSet, Hashable, Sendable {
    /// The raw bit set backing the option set.
    public let rawValue: Int

    /// Creates a modifier set from a raw bit set.
    /// - Parameter rawValue: The combined option bits.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The Shift modifier.
    public static let shift = TerminalKeyModifier(rawValue: 1 << 0)
    /// The Control modifier.
    public static let control = TerminalKeyModifier(rawValue: 1 << 1)
    /// The Option / Alt modifier.
    public static let alternate = TerminalKeyModifier(rawValue: 1 << 2)
}
