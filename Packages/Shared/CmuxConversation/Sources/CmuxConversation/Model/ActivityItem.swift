/// Something the agent does on the user's behalf: a tool call, a command,
/// an edit, a search.
public struct ActivityItem: Hashable, Sendable {
    /// What kind of work it is, when the backend says (`read`, `edit`,
    /// `execute`, `search`, `fetch`, `think`, `other`).
    public var kind: String
    /// A one-line description.
    public var title: String
    /// `pending`, `in_progress`, `completed` or `failed`.
    public var status: String
    /// Longer output or a diff, when the backend sends one.
    public var detail: String

    /// Creates an activity.
    /// - Parameters:
    ///   - kind: Kind of work.
    ///   - title: One-line description.
    ///   - status: Progress state.
    ///   - detail: Output or diff text.
    public init(kind: String, title: String, status: String, detail: String = "") {
        self.kind = kind
        self.title = title
        self.status = status
        self.detail = detail
    }

    /// Whether the activity has finished, successfully or not.
    public var isFinished: Bool { status == "completed" || status == "failed" }
}
