public import CmuxHomeCore

/// A message's text as the transcript shows it, flattened for a one-line
/// preview (a sidebar row, a pinned tile): an agent's Markdown loses its
/// markers through the transcript's own parser (`HomeMarkdown`: bold,
/// italic, strike, code, links, headings, bullets), and anyone else's text
/// stays as written, as in the transcript (`HomeMapping.isAgent`).
public struct HomeMarkdownPreview: Sendable {
    public let text: String

    public init(_ source: String, author: ParticipantID, in summary: ConversationSummary?) {
        text = HomeMapping.isAgent(author, summary) ? HomeMarkdown.render(source).text : source
    }
}
