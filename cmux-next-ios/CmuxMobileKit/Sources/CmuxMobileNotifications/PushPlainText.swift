import Foundation

/// Markdown made into the plain text a notification shows: emphasis, code
/// and link syntax removed, link text kept, line breaks kept.
public struct PushPlainText: Sendable, Equatable {
    public let text: String

    public init(markdown: String) {
        #if canImport(Darwin)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: markdown, options: options) {
            text = String(parsed.characters)
        } else {
            text = markdown
        }
        #else
        // Linux Foundation parses no Markdown; the package lane skips the tests that read this.
        text = markdown
        #endif
    }
}
