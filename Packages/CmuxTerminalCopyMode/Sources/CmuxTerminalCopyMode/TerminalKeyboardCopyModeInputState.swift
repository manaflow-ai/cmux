/// Incremental keyboard state for multi-key terminal copy-mode commands.
public struct TerminalKeyboardCopyModeInputState: Equatable, Sendable {
    /// The numeric prefix collected before a command.
    public var countPrefix: Int?

    /// Whether `y` has been pressed as a pending line-yank operator.
    public var pendingYankLine: Bool

    /// Whether `g` has been pressed as a pending jump prefix.
    public var pendingG: Bool

    /// Creates an input state snapshot.
    ///
    /// - Parameters:
    ///   - countPrefix: The numeric prefix collected before a command.
    ///   - pendingYankLine: Whether `y` is waiting for a second `y`.
    ///   - pendingG: Whether `g` is waiting for a second `g`.
    public init(
        countPrefix: Int? = nil,
        pendingYankLine: Bool = false,
        pendingG: Bool = false
    ) {
        self.countPrefix = countPrefix
        self.pendingYankLine = pendingYankLine
        self.pendingG = pendingG
    }

    /// Clears all pending multi-key command state.
    public mutating func reset() {
        countPrefix = nil
        pendingYankLine = false
        pendingG = false
    }
}
