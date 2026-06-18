/// A terminal copy-mode command resolved from one keyboard input sequence.
///
/// `TerminalKeyboardCopyModeAction` is the semantic command layer between raw
/// keyboard events and the terminal host. Resolvers such as
/// ``terminalKeyboardCopyModeAction(keyCode:charactersIgnoringModifiers:modifiers:hasSelection:asciiCharacterProvider:)``
/// produce these values; the AppKit integration decides how to apply the
/// resulting viewport scroll, cursor movement, search, copy, or exit action.
///
/// ```swift
/// let action: TerminalKeyboardCopyModeAction = .adjustSelection(.down)
/// switch action {
/// case .adjustSelection(let move):
///     print("move cursor or selection endpoint: \(move)")
/// case .exit:
///     print("leave copy mode")
/// default:
///     break
/// }
/// ```
///
/// Use ``adjustSelection(_:)`` with ``TerminalKeyboardCopyModeSelectionMove`` for
/// both non-visual cursor motion and visual-selection endpoint motion. The enum
/// has no initializer parameters and does not throw.
public enum TerminalKeyboardCopyModeAction: Equatable, Sendable {
    /// Leaves keyboard copy mode.
    case exit

    /// Starts visual selection at the current copy-mode cursor.
    case startSelection

    /// Clears the active visual selection while staying in copy mode.
    case clearSelection

    /// Copies the active visual selection and exits copy mode.
    case copyAndExit

    /// Copies one or more full viewport lines and exits copy mode.
    case copyLineAndExit

    /// Scrolls the viewport by a signed number of lines.
    case scrollLines(Int)

    /// Scrolls the viewport by a signed number of pages.
    case scrollPage(Int)

    /// Scrolls the viewport by a signed number of half pages.
    case scrollHalfPage(Int)

    /// Jumps the viewport and cursor to the top-left cell.
    case scrollToTop

    /// Jumps the viewport and cursor to the bottom-right cell.
    case scrollToBottom

    /// Jumps by a signed number of shell prompts.
    case jumpToPrompt(Int)

    /// Opens terminal search from copy mode.
    case startSearch

    /// Moves to the next search result.
    case searchNext

    /// Moves to the previous search result.
    case searchPrevious

    /// Moves the copy-mode cursor or extends visual selection.
    ///
    /// - Parameter move: The cursor or endpoint movement to apply.
    case adjustSelection(TerminalKeyboardCopyModeSelectionMove)
}
