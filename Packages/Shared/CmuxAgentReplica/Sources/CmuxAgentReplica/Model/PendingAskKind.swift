import Foundation

/// Describes the kind of pending user ask.
public enum PendingAskKind: String, Codable, Hashable, Sendable {
    /// A question requiring an answer.
    case question
    /// A permission request requiring a decision.
    case permission
}
