import Foundation

/// Markdown made into the plain text a notification shows: emphasis, code
/// and link syntax removed, link text kept, line breaks kept.
public struct PushPlainText: Sendable, Equatable {
    public let text: String

    public init(markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: markdown, options: options) {
            text = String(parsed.characters)
        } else {
            text = markdown
        }
    }
}
