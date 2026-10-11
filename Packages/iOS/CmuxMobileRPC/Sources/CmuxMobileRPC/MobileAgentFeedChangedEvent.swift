public import Foundation

/// The revision-only payload emitted on `feed.changed`.
public struct MobileAgentFeedChangedEvent: Decodable, Equatable, Sendable {
    /// The newest workstream-feed revision known by the Mac.
    public let revision: Int

    /// Decodes an agent-feed invalidation event.
    /// - Parameter data: The raw event payload.
    /// - Returns: The decoded event, or `nil` when the payload is malformed.
    public static func decode(_ data: Data) -> MobileAgentFeedChangedEvent? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}
