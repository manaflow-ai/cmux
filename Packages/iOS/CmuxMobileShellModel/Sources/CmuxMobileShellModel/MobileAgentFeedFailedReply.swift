import Foundation

/// A Feed terminal reply that did not finish, kept so the row can say so and
/// offer the user's text back instead of dropping it.
public struct MobileAgentFeedFailedReply: Equatable, Sendable {
    /// How far the reply got before failing.
    public enum Delivery: Equatable, Sendable {
        /// The request never reached the Mac, so nothing was typed.
        case notSent
        /// The request reached the Mac, or its fate is unknown, so the text
        /// may already be in the terminal. A retry must be the user's choice
        /// after checking, never automatic, so the text is not typed twice.
        case unconfirmed
    }

    public let text: String
    public let delivery: Delivery

    public init(text: String, delivery: Delivery) {
        self.text = text
        self.delivery = delivery
    }
}
