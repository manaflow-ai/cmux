internal import Foundation

/// The reconciled lifecycle state exposed to sidebar and hibernation consumers.
public nonisolated enum AgentLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    /// No authoritative running or terminal evidence is available.
    case unknown
    /// The agent is actively processing a turn.
    case running
    /// The agent is settled and may be eligible for hibernation.
    case idle
    /// The agent is waiting for user input.
    case needsInput

    /// Decodes a lifecycle value while preserving forward compatibility.
    ///
    /// Unknown raw values decode as ``unknown``.
    ///
    /// - Parameter decoder: The decoder providing the raw lifecycle string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(cliValue: rawValue) ?? .unknown
    }

    /// Whether this state permits routine agent hibernation.
    public var allowsHibernation: Bool {
        self == .idle
    }

    /// Encodes the canonical raw lifecycle value.
    ///
    /// - Parameter encoder: The encoder receiving the lifecycle string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Creates a lifecycle state from a token accepted by the CLI.
    ///
    /// - Parameter cliValue: A case-insensitive lifecycle token.
    public init?(cliValue rawValue: String) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "unknown": self = .unknown
        case "running": self = .running
        case "idle": self = .idle
        case "needsinput", "needs-input": self = .needsInput
        default: return nil
        }
    }
}
