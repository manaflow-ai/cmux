/// The effort and model a matrix cell asks for. A `nil` field means "leave unchanged".
public struct SessionPriorityTarget: Equatable, Codable, Sendable {
    /// The effort level to apply, if any.
    public var effort: ClaudeEffortLevel?
    /// The model alias or id to apply, if any.
    public var model: String?

    /// Creates a target.
    public init(effort: ClaudeEffortLevel? = nil, model: String? = nil) {
        self.effort = effort
        self.model = model
    }

    /// Whether the target asks for nothing.
    public var isEmpty: Bool { effort == nil && model == nil }
}
