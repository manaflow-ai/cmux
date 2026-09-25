/// Authoritative objective state bound to one provider session generation.
public struct AgentGoalLifecycle: Codable, Sendable, Equatable {
    /// The objective state.
    public let state: AgentGoalLifecycleState
    /// Provider- or cmux-stable identity for this exact objective generation.
    public let generation: String
    /// Producer timestamp in milliseconds since the Unix epoch.
    public let updatedAtMs: Int64
    /// Bounded source label, such as `provider_hook` or `generic_hook`.
    public let provenance: String

    /// Expected current generation when explicitly replacing an objective.
    public let previousGeneration: String?

    /// Creates an objective lifecycle value.
    ///
    /// - Parameters:
    ///   - state: The objective state.
    ///   - generation: Stable identity for this objective generation.
    ///   - updatedAtMs: Producer timestamp in milliseconds since the Unix epoch.
    ///   - provenance: Source label for the authoritative update.
    ///   - previousGeneration: Compare-and-set fence when replacing an objective.
    public init(
        state: AgentGoalLifecycleState,
        generation: String,
        updatedAtMs: Int64,
        provenance: String,
        previousGeneration: String? = nil
    ) {
        self.state = state
        self.generation = generation
        self.updatedAtMs = updatedAtMs
        self.provenance = provenance
        self.previousGeneration = previousGeneration
    }

    /// Validates the bounded, privacy-safe wire fields.
    ///
    /// - Returns: A validation problem, or `nil` when the value is admissible.
    public func validationProblem() -> String? {
        guard !generation.isEmpty, generation.count <= 128 else {
            return "generation must be 1-128 characters"
        }
        guard generation.utf8.allSatisfy({ (33...126).contains($0) }) else {
            return "generation contains an invalid character"
        }
        if let previousGeneration, previousGeneration.isEmpty || previousGeneration.count > 128
            || !previousGeneration.utf8.allSatisfy({ (33...126).contains($0) }) {
            return "previous_generation must be a bounded opaque identifier"
        }
        guard updatedAtMs >= 0 else { return "updated_at_ms must be >= 0" }
        guard !provenance.isEmpty, provenance.count <= 64 else {
            return "provenance must be 1-64 characters"
        }
        guard provenance.allSatisfy({ character in
            character.isASCII && (character.isLowercase || character.isNumber
                || character == "." || character == "_" || character == "-")
        }) else {
            return "provenance must be a lowercase slug"
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case generation
        case updatedAtMs = "updated_at_ms"
        case provenance
        case previousGeneration = "previous_generation"
    }
}
