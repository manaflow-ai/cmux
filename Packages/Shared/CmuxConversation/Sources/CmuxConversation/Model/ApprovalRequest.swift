/// The agent asks the user before doing something, or asks a question with
/// fixed answers.
public struct ApprovalRequest: Hashable, Sendable {
    /// The backend's identifier, used to answer.
    public let id: String
    /// What the agent wants to do, or the question.
    public var title: String
    /// The answers on offer.
    public var options: [ApprovalOption]
    /// The chosen answer's id, once answered (by anyone, or automatically).
    public var decision: String?

    /// Creates a request.
    /// - Parameters:
    ///   - id: The backend's identifier.
    ///   - title: What the agent wants to do.
    ///   - options: The answers on offer.
    ///   - decision: The chosen answer, if already decided.
    public init(id: String, title: String, options: [ApprovalOption], decision: String? = nil) {
        self.id = id
        self.title = title
        self.options = options
        self.decision = decision
    }

    /// Whether it still waits for an answer.
    public var isPending: Bool { decision == nil }
}
