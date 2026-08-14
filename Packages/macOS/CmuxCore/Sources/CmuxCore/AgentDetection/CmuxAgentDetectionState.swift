internal import Foundation

/// The terminal states a manifest may identify, evaluated in rule order.
public enum CmuxAgentDetectionState: String, CaseIterable, Codable, Hashable, Sendable {
    /// The agent is at its input prompt and not actively processing.
    case idle
    /// The agent is actively processing a turn.
    case working
    /// The agent is waiting for user input for a non-permission reason.
    case blocked
    /// The agent is asking the user to approve a permission request.
    case permissionPrompt = "permission-prompt"
    /// The agent reports that its turn completed.
    case done

    /// Decodes canonical names and compatibility aliases used by manifests.
    ///
    /// - Parameter decoder: Decoder positioned at a state string.
    /// - Throws: ``DecodingError`` when the string is not a supported state.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "idle": self = .idle
        case "working", "running", "busy": self = .working
        case "blocked", "needs-input", "needs_input": self = .blocked
        case "permission-prompt", "permission_prompt", "permissionprompt", "permission":
            self = .permissionPrompt
        case "done", "complete", "completed": self = .done
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: CmuxAgentManifestCodec.localizedReason(
                    "agentManifest.validation.unknownState",
                    defaultValue: "Unknown agent detection state '%@'",
                    arguments: [value]
                )
            )
        }
    }

    /// Encodes the canonical hyphenated state name.
    ///
    /// - Parameter encoder: Encoder receiving the canonical state string.
    /// - Throws: Any error reported by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
