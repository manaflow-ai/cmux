public import AppKit
public import CmuxNextDesign

/// Comment… on selected text in a viewer (viewer-comments-DESIGN.md): a cmux dialog titled with the
/// quote's card title, the quoted text under it, one comment field, Cancel and Add to Chat.
@MainActor
public struct ViewerCommentPrompt {
    /// The comment field's id in the dialog's answer.
    static let field = "comment"
    /// The Add to Chat button's id.
    static let add = "addToChat"

    public let quote: ChatQuote

    /// A prompt for `quote` (its ``ChatQuote/comment`` is ignored; the answer sets it).
    public init(quote: ChatQuote) {
        self.quote = quote
    }

    /// The dialog: the title, a preview of the quoted text (at most four lines), the field and buttons.
    public var spec: CmuxDialogSpec {
        let lines = quote.quoted.split(separator: "\n", omittingEmptySubsequences: true)
        var preview = lines.prefix(4).joined(separator: "\n")
        if lines.count > 4 { preview += "\n…" }
        return CmuxDialogSpec(title: ViewerSelectionMenu.Titles.commentOn(quote.title), lines: [preview],
                              fields: [.text(Self.field, placeholder: ViewerSelectionMenu.Titles.commentPlaceholder)],
                              buttons: [.cancel(), CmuxDialogButton(id: Self.add, title: ViewerSelectionMenu.Titles.addToChat, role: .default)],
                              identifier: "cmux.dialog.viewerComment")
    }

    /// The quote with the user's comment for `answer`, nil when the user cancelled.
    public func quote(for answer: CmuxDialogAnswer) -> ChatQuote? {
        guard answer.button == Self.add else { return nil }
        var quote = quote
        quote.comment = answer.text(Self.field)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return quote
    }

    /// Shows the prompt over `window`; `completion` gets the commented quote unless the user cancels.
    public func run(in window: NSWindow, completion: @escaping (ChatQuote) -> Void) {
        CmuxDialogCenter.shared.present(spec, in: .window(window)) { answer in
            if let quote = quote(for: answer) { completion(quote) }
        }
    }
}
