/// Execution mode observed independently of activity and review requests.
public enum AgentExecutionMode: String, Codable, Sendable, CaseIterable, Equatable {
    /// The mode is not known.
    case unknown
    /// The session is in planning mode.
    case plan
    /// The session is in execution mode, including native build mode.
    case execution

    /// Decodes unknown additive values conservatively.
    /// - Parameter decoder: Journal wire decoder.
    /// - Throws: A decoding error for non-string values.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "build" ? .execution : Self(rawValue: value) ?? .unknown
    }
}
