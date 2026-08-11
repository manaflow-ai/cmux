import Foundation

/// Captures Codex per-turn capability identifiers from `turn_context` records.
public struct TurnContextFact: Hashable, Sendable {
    /// The transcript line that carried the context.
    public let line: Int
    /// The model identifier reported by Codex, when present.
    public let model: String?
    /// The sandbox policy identifier reported by Codex, when present.
    public let sandboxPolicy: String?
    /// The approval policy identifier reported by Codex, when present.
    public let approvalPolicy: String?

    /// Creates a turn context fact.
    /// - Parameters:
    ///   - line: The transcript line that carried the context.
    ///   - model: The model identifier reported by Codex.
    ///   - sandboxPolicy: The sandbox policy identifier reported by Codex.
    ///   - approvalPolicy: The approval policy identifier reported by Codex.
    public init(line: Int, model: String?, sandboxPolicy: String?, approvalPolicy: String?) {
        self.line = line
        self.model = model
        self.sandboxPolicy = sandboxPolicy
        self.approvalPolicy = approvalPolicy
    }
}
