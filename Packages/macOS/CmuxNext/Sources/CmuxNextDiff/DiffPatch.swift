/// A patch a diff tab shows in place of a repository's diff: a chat turn's own changes (the agent
/// pane's View changes on a turn its folder's diff does not hold), as unified diff `text`, under
/// `title` (the chat folder's name; empty for the viewer's own title).
public nonisolated struct DiffPatch: Sendable, Equatable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}
