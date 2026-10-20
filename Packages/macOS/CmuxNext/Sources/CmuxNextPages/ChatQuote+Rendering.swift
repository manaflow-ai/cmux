public import Foundation

extension ChatQuote {
    /// The card's title: the source's last path component and the line range, `README.md · L12–18`.
    public var title: String {
        ""
    }

    /// The text a chat sends for this quote: a Markdown block quote headed by the bold ``title``,
    /// then the comment after a blank line.
    public var markdown: String {
        ""
    }
}
