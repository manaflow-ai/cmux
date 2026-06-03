import Foundation

/// The request body to send a test push notification to the current user.
public struct MobilePushTestRequest: Encodable, Equatable, Sendable {
    /// The notification title.
    public let title: String

    /// The notification body text.
    public let body: String

    /// Creates a test-push request.
    ///
    /// - Parameters:
    ///   - title: The notification title.
    ///   - body: The notification body text.
    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}
