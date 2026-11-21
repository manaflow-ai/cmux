public import CmuxHomeCore

/// A message's text flattened for a one-line preview (a sidebar row, a
/// pinned tile, a reaction's quote): an agent's Markdown shows its words,
/// never its syntax (``MessagePreview``: links by their labels, a table by
/// its column titles, pictures left out or counted), and anyone else's text
/// stays as written, as in the transcript (`HomeMapping.isAgent`).
public struct HomeMarkdownPreview: Sendable {
    public let text: String

    public init(_ source: String, author: ParticipantID, in summary: ConversationSummary?) {
        HomeMarkdownPolicy.install()
        text = HomeMapping.isAgent(author, summary) ? MessagePreview(markdown: source).text(.home) : source
    }
}
