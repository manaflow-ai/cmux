public import Foundation

/// Timing for content-follow updates while the software keyboard is visible.
/// Keyboard show/hide transitions have their own timing and are not governed
/// by this policy.
public struct TerminalKeyboardAbsorptionAnimation: Sendable {
    /// Creates the content-follow animation policy.
    public init() {}

    /// Content measurements can change on consecutive display frames as input
    /// wraps. Apply them immediately so a new measurement cannot retarget an
    /// unfinished animation and keep the terminal moving after typing stops.
    public var duration: TimeInterval { 0 }
}
