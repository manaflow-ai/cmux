public import Foundation

/// Defines the exact modifier chord that reserves a terminal click for link activation.
public struct TerminalLinkActivationPolicy: Sendable {
    /// Creates the terminal link activation policy.
    public init() {}

    /// Returns whether a press is the exact Command-click link chord.
    ///
    /// AppKit supplies the raw modifier values, while the policy stays free of
    /// AppKit so its authorization contract can be tested with SwiftPM.
    ///
    /// - Parameters:
    ///   - modifierFlagsRawValue: Device-independent modifier flags at press time.
    ///   - commandModifierRawValue: The platform's raw Command modifier bit.
    ///   - capsLockModifierRawValue: The platform's raw Caps Lock modifier bit,
    ///     which does not change the click chord.
    ///   - isInsideBounds: Whether the press landed inside the terminal view.
    /// - Returns: `true` only when Command is the sole activation modifier after
    ///   Caps Lock is ignored.
    public func permitsCommandClick(
        modifierFlagsRawValue: UInt,
        commandModifierRawValue: UInt,
        capsLockModifierRawValue: UInt,
        isInsideBounds: Bool
    ) -> Bool {
        let chordModifierFlagsRawValue = modifierFlagsRawValue & ~capsLockModifierRawValue
        return isInsideBounds && chordModifierFlagsRawValue == commandModifierRawValue
    }
}
