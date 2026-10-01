/// One step of the agent's plan.
public struct PlanEntry: Hashable, Sendable {
    /// The step's text.
    public var content: String
    /// `pending`, `in_progress` or `completed`.
    public var status: String

    /// Creates a plan step.
    /// - Parameters:
    ///   - content: The step's text.
    ///   - status: Its progress.
    public init(content: String, status: String) {
        self.content = content
        self.status = status
    }
}
