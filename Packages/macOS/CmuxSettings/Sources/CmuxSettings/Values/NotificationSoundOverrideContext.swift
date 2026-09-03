import Foundation

/// The stable identity carried from an agent notification source to sound delivery.
nonisolated public struct NotificationSoundOverrideContext: Codable, Equatable, Hashable, Sendable {
    /// The stable registry identifier for the agent that produced the alert.
    public let agentID: String
    /// The semantic alert class used to select the matrix cell.
    public let alertType: NotificationSoundAlertType

    /// Creates a context when `agentID` has a valid declarative-settings form.
    ///
    /// - Parameters:
    ///   - agentID: The stable agent-registry identifier.
    ///   - alertType: The semantic class of the alert.
    public init?(agentID: String, alertType: NotificationSoundAlertType) {
        let normalized = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidAgentID(normalized) else { return nil }
        self.agentID = normalized
        self.alertType = alertType
    }

    private enum CodingKeys: String, CodingKey {
        case agentID
        case alertType
    }

    /// Decodes and validates a notification sound context.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let agentID = try container.decode(String.self, forKey: .agentID)
        let alertType = try container.decode(NotificationSoundAlertType.self, forKey: .alertType)
        guard let value = Self.init(agentID: agentID, alertType: alertType) else {
            throw DecodingError.dataCorruptedError(
                forKey: .agentID,
                in: container,
                debugDescription: "Invalid notification sound override agent id"
            )
        }
        self = value
    }

    /// Encodes the stable agent identifier and alert type.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentID, forKey: .agentID)
        try container.encode(alertType, forKey: .alertType)
    }

    /// Returns whether a string is a bounded, case-preserving registry key.
    public static func isValidAgentID(_ value: String) -> Bool {
        guard value != ".", value != "..", !value.isEmpty, value.count <= 64 else {
            return false
        }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isUppercase || character.isLowercase || character.isNumber
                    || character == "." || character == "_" || character == "-")
        }
    }
}
