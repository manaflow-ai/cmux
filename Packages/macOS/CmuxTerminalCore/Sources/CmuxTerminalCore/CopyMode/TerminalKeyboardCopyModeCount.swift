/// The largest repeat count accepted by terminal keyboard copy mode.
///
/// ``terminalKeyboardCopyModeClampCount(_:)`` uses this value to keep numeric
/// prefixes bounded before actions such as ``TerminalKeyboardCopyModeAction.adjustSelection(_:)``
/// are applied.
///
/// ```swift
/// let count = terminalKeyboardCopyModeClampCount(20_000)
/// // count == terminalKeyboardCopyModeMaxCount
/// ```
public let terminalKeyboardCopyModeMaxCount = 9_999

/// Clamps a command repeat count into the range accepted by terminal keyboard copy mode.
///
/// Use this at the host boundary before applying a stored numeric prefix to a
/// ``TerminalKeyboardCopyModeAction``. Values smaller than one become `1`; values
/// larger than ``terminalKeyboardCopyModeMaxCount`` become that maximum.
///
/// ```swift
/// terminalKeyboardCopyModeClampCount(0) == 1
/// terminalKeyboardCopyModeClampCount(20_000) == terminalKeyboardCopyModeMaxCount
/// ```
///
/// - Parameter value: The raw count parsed from user input.
/// - Returns: A count between `1` and ``terminalKeyboardCopyModeMaxCount``.
public func terminalKeyboardCopyModeClampCount(_ value: Int) -> Int {
    min(max(value, 1), terminalKeyboardCopyModeMaxCount)
}
