import Foundation

/// Pure transform deciding whether a committed, unmodified block of text should
/// be sent as per-character input or as a bracketed paste.
///
/// Extracted from the iOS input view so the input-vs-paste policy is testable
/// without a `UITextView`. The view calls ``route(for:)`` for the no-modifier
/// commit path; any active Ctrl/Alt/Cmd/Shift modifier is resolved before this
/// (those always use the per-key input/escape paths).
///
/// ```swift
/// switch TerminalCommitRouter.route(for: text) {
/// case .input: onText?(text)
/// case .paste: onPasteText?(text)
/// }
/// ```
public struct TerminalCommitRouter {
    private init() {}

    /// Classifies a committed block by character count.
    ///
    /// A block of more than one character (counted by `Character`, so an emoji
    /// or other grapheme cluster is one) is treated as a paste; anything else
    /// stays per-character input. The text is not transformed here.
    /// - Parameter text: The committed block (already modifier-resolved).
    /// - Returns: ``TerminalCommitRoute/paste`` for a multi-character block,
    ///   otherwise ``TerminalCommitRoute/input``.
    public static func route(for text: String) -> TerminalCommitRoute {
        text.count > 1 ? .paste : .input
    }
}
