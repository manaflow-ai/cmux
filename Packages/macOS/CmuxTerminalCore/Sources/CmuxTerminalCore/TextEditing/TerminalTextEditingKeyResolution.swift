/// Virtual key codes the text-editing resolver recognises.
///
/// These mirror the Carbon `kVK_*` constants the app target already uses, kept
/// here so the package stays free of a Carbon dependency.
enum TerminalTextEditingKeyCode {
    /// `kVK_Delete` — the Backspace key.
    static let backspace: UInt16 = 0x33
    /// `kVK_ForwardDelete` — the forward Delete key.
    static let forwardDelete: UInt16 = 0x75
    /// `kVK_LeftArrow`.
    static let leftArrow: UInt16 = 0x7B
    /// `kVK_RightArrow`.
    static let rightArrow: UInt16 = 0x7C
}

/// A resolved text-editing gesture, expressed as the bytes to send to the PTY.
///
/// The resolver never mutates terminal state itself. It answers only "which
/// bytes does this gesture mean to the remote line editor", so the caller can
/// write them through the ordinary input path.
public struct TerminalTextEditingAction: Equatable, Sendable {
    /// The bytes to write to the PTY.
    public let bytes: [UInt8]

    /// Creates an action from the bytes a gesture sends.
    ///
    /// - Parameter bytes: The bytes to write to the PTY.
    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// `Ctrl+A` — move to the beginning of the line.
    static let beginningOfLine = TerminalTextEditingAction(bytes: [0x01])
    /// `Ctrl+E` — move to the end of the line.
    static let endOfLine = TerminalTextEditingAction(bytes: [0x05])
    /// `Alt+b` — move backward one word.
    static let backwardWord = TerminalTextEditingAction(bytes: [0x1B, 0x62])
    /// `Alt+f` — move forward one word.
    static let forwardWord = TerminalTextEditingAction(bytes: [0x1B, 0x66])
    /// `Ctrl+U` — kill from the cursor to the beginning of the line.
    static let killToLineStart = TerminalTextEditingAction(bytes: [0x15])
    /// `Ctrl+K` — kill from the cursor to the end of the line.
    static let killToLineEnd = TerminalTextEditingAction(bytes: [0x0B])
    /// `Ctrl+W` — kill the word before the cursor.
    static let killBackwardWord = TerminalTextEditingAction(bytes: [0x17])
    /// `Alt+d` — kill the word after the cursor.
    static let killForwardWord = TerminalTextEditingAction(bytes: [0x1B, 0x64])
}

/// Strips modifiers that never participate in gesture matching.
private func terminalTextEditingNormalizedModifiers(
    _ modifiers: TerminalTextEditingModifiers
) -> TerminalTextEditingModifiers {
    modifiers.subtracting([.numericPad, .function, .capsLock])
}

/// Resolves a macOS text-editing gesture into the bytes its line-editor equivalent sends.
///
/// Returns `nil` for anything the mode does not own, which the caller must pass
/// through untouched. In particular this returns `nil` for every event carrying
/// Control, so `Ctrl+C` and friends keep reaching the remote unchanged, and for
/// Shift combinations, because readline and zle have no selection model for a
/// shift-extended gesture to target.
///
/// `Cmd+A` is deliberately unmapped. In macOS it means select-all, which has no
/// line-editor equivalent, and silently repurposing it as "beginning of line"
/// would give the chord a second meaning users did not ask for.
///
/// ```swift
/// let action = terminalTextEditingResolve(
///     keyCode: 0x7B, // Left arrow
///     modifiers: [.option]
/// )
/// // action?.bytes == [0x1B, 0x62]  (Alt+b, backward-word)
/// ```
///
/// - Parameters:
///   - keyCode: The virtual key code of the event.
///   - modifiers: The event modifiers, already mapped off AppKit.
/// - Returns: The action to send, or `nil` when the event is not a text-editing
///   gesture and should pass through to the terminal unchanged.
public func terminalTextEditingResolve(
    keyCode: UInt16,
    modifiers: TerminalTextEditingModifiers
) -> TerminalTextEditingAction? {
    let normalized = terminalTextEditingNormalizedModifiers(modifiers)

    // Control-bearing events stay with the remote application, always.
    guard !normalized.contains(.control) else { return nil }

    // No selection model downstream, so a shift-extended gesture has nothing to
    // resolve to. Pass it through rather than dropping the shift silently.
    guard !normalized.contains(.shift) else { return nil }

    let hasCommand = normalized.contains(.command)
    let hasOption = normalized.contains(.option)

    // Exactly one of Command or Option selects the gesture family. Both at once
    // is ambiguous, and neither means an ordinary keystroke.
    guard hasCommand != hasOption else { return nil }

    if hasCommand {
        switch keyCode {
        case TerminalTextEditingKeyCode.leftArrow: return .beginningOfLine
        case TerminalTextEditingKeyCode.rightArrow: return .endOfLine
        case TerminalTextEditingKeyCode.backspace: return .killToLineStart
        case TerminalTextEditingKeyCode.forwardDelete: return .killToLineEnd
        default: return nil
        }
    }

    switch keyCode {
    case TerminalTextEditingKeyCode.leftArrow: return .backwardWord
    case TerminalTextEditingKeyCode.rightArrow: return .forwardWord
    case TerminalTextEditingKeyCode.backspace: return .killBackwardWord
    case TerminalTextEditingKeyCode.forwardDelete: return .killForwardWord
    default: return nil
    }
}
