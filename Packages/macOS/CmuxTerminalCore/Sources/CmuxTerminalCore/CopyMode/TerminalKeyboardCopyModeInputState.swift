/// Incremental keyboard state for multi-key terminal copy-mode commands.
///
/// `TerminalKeyboardCopyModeInputState` stores the small amount of resolver
/// state that survives between key events: numeric prefixes, `yy`, and `gg`.
/// Pass one mutable instance into
/// ``terminalKeyboardCopyModeResolve(keyCode:charactersIgnoringModifiers:modifiers:hasSelection:state:asciiCharacterProvider:)``
/// for the lifetime of a copy-mode session, then call ``reset()`` when the host
/// exits copy mode.
///
/// ```swift
/// var state = TerminalKeyboardCopyModeInputState()
/// state.countPrefix = 2
/// state.pendingYankLine = true
/// state.reset()
/// ```
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
    ///
    /// After calling this method, ``countPrefix``, ``pendingYankLine``, and
    /// ``pendingG`` return to their initial values. The method mutates the state
    /// in place and returns no value.
    public mutating func reset() {
        countPrefix = nil
        pendingYankLine = false
        pendingG = false
    }
}
