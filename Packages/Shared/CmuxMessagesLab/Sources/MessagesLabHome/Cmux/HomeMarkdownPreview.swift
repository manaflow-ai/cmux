public import CmuxHomeCore

<<<<<<< HEAD
/// A message's text flattened for a one-line preview (a sidebar row, a
/// pinned tile, a reaction's quote): an agent's Markdown shows its words,
/// never its syntax (``MessagePreview``: links by their labels, a table by
/// its column titles, pictures left out or counted), and anyone else's text
=======
/// A message's text as the transcript shows it, flattened for a one-line
/// preview (a sidebar row, a pinned tile): an agent's Markdown loses its
/// markers through the transcript's own parser (`HomeMarkdown`: bold,
/// italic, strike, code, links, headings, bullets), and anyone else's text
>>>>>>> origin/main
/// stays as written, as in the transcript (`HomeMapping.isAgent`).
public struct HomeMarkdownPreview: Sendable {
    public let text: String

    public init(_ source: String, author: ParticipantID, in summary: ConversationSummary?) {
        HomeMarkdownPolicy.install()
<<<<<<< HEAD
        text = HomeMapping.isAgent(author, summary) ? MessagePreview(markdown: source).text(.home) : source
=======
        text = HomeMapping.isAgent(author, summary) ? HomeMarkdown.render(source).text : source
>>>>>>> origin/main
    }
}
