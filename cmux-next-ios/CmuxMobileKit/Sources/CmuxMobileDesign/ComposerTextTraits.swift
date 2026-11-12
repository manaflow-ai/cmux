#if os(iOS)
import UIKit

/// The keyboard's text traits for each kind of text field that takes typing
/// (user, 2026-11-12: "hm no autocorrect i guess thats maybe ok").
///
/// - `prose`: the agent chat composer. A message to an agent is written
///   language: autocorrection, spell checking, sentence capitals, smart
///   quotes and dashes, as in Messages.
/// - `terminalMessage`: the terminal's message composer, whose draft is
///   pasted into the program (mostly a prompt to an agent running there).
///   Autocorrection, spell checking and sentence capitals as in `prose`; smart
///   quotes, dashes and insert-delete stay off, since a curly quote or an en
///   dash in a shell command changes what the command does.
/// - The terminal's own key input (the hidden field that sends each key to
///   the PTY, `TerminalSurfaceView`) is not a composer and takes none of
///   these: every trait there stays off.
public struct ComposerTextTraits: Equatable, Sendable {
    public var autocorrection: UITextAutocorrectionType
    public var spellChecking: UITextSpellCheckingType
    public var autocapitalization: UITextAutocapitalizationType
    public var smartQuotes: UITextSmartQuotesType
    public var smartDashes: UITextSmartDashesType
    public var smartInsertDelete: UITextSmartInsertDeleteType

    public static let prose = ComposerTextTraits(
        autocorrection: .yes, spellChecking: .yes, autocapitalization: .sentences,
        smartQuotes: .yes, smartDashes: .yes, smartInsertDelete: .yes)

    public static let terminalMessage = ComposerTextTraits(
        autocorrection: .yes, spellChecking: .yes, autocapitalization: .sentences,
        smartQuotes: .no, smartDashes: .no, smartInsertDelete: .no)

    /// The traits a text input has now.
    @MainActor
    public init(of input: any UITextInputTraits) {
        self.init(autocorrection: input.autocorrectionType ?? .default,
                  spellChecking: input.spellCheckingType ?? .default,
                  autocapitalization: input.autocapitalizationType ?? .sentences,
                  smartQuotes: input.smartQuotesType ?? .default,
                  smartDashes: input.smartDashesType ?? .default,
                  smartInsertDelete: input.smartInsertDeleteType ?? .default)
    }

    public init(autocorrection: UITextAutocorrectionType, spellChecking: UITextSpellCheckingType,
                autocapitalization: UITextAutocapitalizationType, smartQuotes: UITextSmartQuotesType,
                smartDashes: UITextSmartDashesType, smartInsertDelete: UITextSmartInsertDeleteType) {
        self.autocorrection = autocorrection
        self.spellChecking = spellChecking
        self.autocapitalization = autocapitalization
        self.smartQuotes = smartQuotes
        self.smartDashes = smartDashes
        self.smartInsertDelete = smartInsertDelete
    }

    @MainActor
    public func apply(to view: UITextView) {
        view.autocorrectionType = autocorrection
        view.spellCheckingType = spellChecking
        view.autocapitalizationType = autocapitalization
        view.smartQuotesType = smartQuotes
        view.smartDashesType = smartDashes
        view.smartInsertDeleteType = smartInsertDelete
    }
}
#endif
