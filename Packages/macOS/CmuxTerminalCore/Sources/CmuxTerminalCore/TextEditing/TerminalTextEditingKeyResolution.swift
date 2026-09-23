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

/// The chord a text-editing gesture stands in for.
///
/// The resolver deliberately names a *chord* rather than the bytes it encodes
/// to. The app target replays the chord through the ordinary key path, so
/// Ghostty performs the encoding and the result stays correct under whichever
/// keyboard protocol the running application negotiated. Emitting raw bytes
/// would bypass that and send legacy control codes to an application expecting
/// `CSI u`.
public struct TerminalTextEditingChord: Equatable, Sendable {
    /// The modifier the replayed chord carries.
    public enum Modifier: Equatable, Sendable {
        /// The Control modifier, as in `Ctrl+A`.
        case control
        /// The Option/Alt modifier, as in `Alt+b`.
        case option
    }

    /// The ASCII lowercase letter of the chord.
    public let letter: Character

    /// The modifier held with ``letter``.
    public let modifier: Modifier

    /// Creates a chord.
    ///
    /// - Parameters:
    ///   - letter: The ASCII lowercase letter of the chord.
    ///   - modifier: The modifier held with `letter`.
    public init(letter: Character, modifier: Modifier) {
        self.letter = letter
        self.modifier = modifier
    }

    /// `Ctrl+A` — move to the beginning of the line.
    static let beginningOfLine = TerminalTextEditingChord(letter: "a", modifier: .control)
    /// `Ctrl+E` — move to the end of the line.
    static let endOfLine = TerminalTextEditingChord(letter: "e", modifier: .control)
    /// `Alt+b` — move backward one word.
    static let backwardWord = TerminalTextEditingChord(letter: "b", modifier: .option)
    /// `Alt+f` — move forward one word.
    static let forwardWord = TerminalTextEditingChord(letter: "f", modifier: .option)
    /// `Ctrl+U` — kill from the cursor to the beginning of the line.
    static let killToLineStart = TerminalTextEditingChord(letter: "u", modifier: .control)
    /// `Ctrl+K` — kill from the cursor to the end of the line.
    static let killToLineEnd = TerminalTextEditingChord(letter: "k", modifier: .control)
    /// `Ctrl+W` — kill the word before the cursor.
    static let killBackwardWord = TerminalTextEditingChord(letter: "w", modifier: .control)
    /// `Alt+d` — kill the word after the cursor.
    static let killForwardWord = TerminalTextEditingChord(letter: "d", modifier: .option)
}

/// Strips modifiers that never participate in gesture matching.
private func terminalTextEditingNormalizedModifiers(
    _ modifiers: TerminalTextEditingModifiers
) -> TerminalTextEditingModifiers {
    modifiers.subtracting([.numericPad, .function, .capsLock])
}

/// Resolves a macOS text-editing gesture into the line-editor chord it stands for.
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
/// let chord = terminalTextEditingResolve(
///     keyCode: 0x7B, // Left arrow
///     modifiers: [.option]
/// )
/// // chord == TerminalTextEditingChord(letter: "b", modifier: .option)
/// ```
///
/// - Parameters:
///   - keyCode: The virtual key code of the event.
///   - modifiers: The event modifiers, already mapped off AppKit.
/// - Returns: The chord to replay, or `nil` when the event is not a
///   text-editing gesture and should pass through to the terminal unchanged.
public func terminalTextEditingResolve(
    keyCode: UInt16,
    modifiers: TerminalTextEditingModifiers
) -> TerminalTextEditingChord? {
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
