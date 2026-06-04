/// The maximum numeric prefix accepted for a keyboard copy-mode command.
public let terminalKeyboardCopyModeMaxCount = 9_999

/// Clamps a command repeat count into the range accepted by keyboard copy mode.
///
/// - Parameter value: The raw count parsed from user input.
/// - Returns: A count between `1` and ``terminalKeyboardCopyModeMaxCount``.
public func terminalKeyboardCopyModeClampCount(_ value: Int) -> Int {
    min(max(value, 1), terminalKeyboardCopyModeMaxCount)
}
