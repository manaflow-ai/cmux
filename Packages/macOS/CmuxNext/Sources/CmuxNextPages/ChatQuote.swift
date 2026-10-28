public import Foundation

/// Selected text from a viewer, with the user's comment, on its way to a chat composer.
///
/// One value for every producer: the Markdown and editor pages' Comment… and Quote in Chat rows,
/// and the design-mode highlight cards. Each chat renders it from ``title`` and ``markdown``
/// (plans/cmux-next/viewer-comments-DESIGN.md).
///
/// ```swift
/// let quote = ChatQuote(source: "/repo/README.md", kind: .markdown, lines: 12...18,
///                       quoted: "Install with brew", comment: "Is this still true?")
/// quote.title // "README.md · L12–18"
/// ```
public nonisolated struct ChatQuote: Hashable, Sendable {
    /// What kind of viewer the text came from.
    public nonisolated enum Kind: String, Hashable, Sendable, CaseIterable {
        /// The Markdown page.
        case markdown
        /// The code editor page.
        case code
        /// The diff page.
        case diff
        /// A PDF in a browser tab.
        case pdf
        /// A web page.
        case web
        /// A design-mode highlight on a page.
        case design
    }

    /// The file path, or the page URL, the text came from.
    public var source: String
    /// The viewer kind.
    public var kind: Kind
    /// The 1-based source line range, nil when the viewer has no lines (a web page).
    public var lines: ClosedRange<Int>?
    /// The selected text as the user saw it.
    public var quoted: String
    /// What the user wrote; empty for Quote in Chat.
    public var comment: String

    /// Makes a quote.
    ///
    /// - Parameters:
    ///   - source: The file path or page URL.
    ///   - kind: The viewer kind.
    ///   - lines: The 1-based line range, nil when there are no lines.
    ///   - quoted: The selected text.
    ///   - comment: The user's comment, empty for none.
    public init(source: String, kind: Kind, lines: ClosedRange<Int>? = nil, quoted: String, comment: String = "") {
        self.source = source
        self.kind = kind
        self.lines = lines
        self.quoted = quoted
        self.comment = comment
    }
}
