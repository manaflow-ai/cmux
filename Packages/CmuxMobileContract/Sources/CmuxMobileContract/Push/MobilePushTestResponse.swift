import Foundation

/// The response to a test-push request, reporting how many notifications were scheduled.
public struct MobilePushTestResponse: Decodable, Equatable, Sendable {
    /// The number of notifications scheduled by the server.
    public let scheduledCount: Int

    /// Creates a test-push response.
    ///
    /// - Parameter scheduledCount: The number of notifications scheduled by the server.
    public init(scheduledCount: Int) {
        self.scheduledCount = scheduledCount
    }
}
