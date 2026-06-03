import Foundation

/// A mobile API response indicating whether a request was accepted for processing.
public struct MobileAcceptedResponse: Decodable, Equatable, Sendable {
    /// Whether the request was accepted.
    public let accepted: Bool

    /// Creates an accepted response.
    ///
    /// - Parameter accepted: Whether the request was accepted.
    public init(accepted: Bool) {
        self.accepted = accepted
    }
}
