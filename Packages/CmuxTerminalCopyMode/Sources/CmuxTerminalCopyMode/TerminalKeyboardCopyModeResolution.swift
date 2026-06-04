/// The result of resolving a keyboard copy-mode key event.
///
/// Resolvers return `TerminalKeyboardCopyModeResolution` so callers can
/// distinguish an event that should perform a counted
/// ``TerminalKeyboardCopyModeAction`` from one that should only update pending
/// resolver state.
///
/// ```swift
/// let resolution: TerminalKeyboardCopyModeResolution = .perform(.adjustSelection(.down), count: 3)
/// switch resolution {
/// case .perform(let action, let count):
///     print("perform \(action) \(count) time(s)")
/// case .consume:
///     print("wait for the next key")
/// }
/// ```
///
/// The enum has no initializer parameters and does not throw.
public enum TerminalKeyboardCopyModeResolution: Equatable, Sendable {
    /// Performs a resolved action with a repeat count.
    ///
    /// - Parameters:
    ///   - action: The copy-mode action to perform.
    ///   - count: The clamped repeat count for the action.
    case perform(TerminalKeyboardCopyModeAction, count: Int)

    /// Consumes the key event without performing an immediate action.
    case consume
}
