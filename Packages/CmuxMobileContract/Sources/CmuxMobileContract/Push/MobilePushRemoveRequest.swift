import Foundation

/// The request body to remove a previously registered APNs push token.
public struct MobilePushRemoveRequest: Encodable, Equatable, Sendable {
    /// The APNs device token to remove, hex-encoded.
    public let token: String

    /// Creates a push removal request.
    ///
    /// - Parameter token: The APNs device token to remove, hex-encoded.
    public init(token: String) {
        self.token = token
    }
}
