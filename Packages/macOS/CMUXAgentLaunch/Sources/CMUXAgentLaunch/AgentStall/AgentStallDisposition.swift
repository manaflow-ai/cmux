import Foundation

/// Describes whether a classified in-session stall may be retried safely.
public enum AgentStallDisposition: String, Codable, Equatable, Sendable {
    /// A transient provider failure that may recover without user action.
    case retryable
    /// A provider or account state that requires a person to intervene.
    case humanRequired
}
