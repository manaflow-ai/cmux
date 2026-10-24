import Foundation

/// `cancel-stream` (`attach-streams-v1`): ends the request's client stream at
/// once, after that stream's earlier requests. The stream id travels in the
/// request envelope (`WireCoding.encodeRequest(_:id:stream:)`), so the request
/// itself has no fields. Idempotent: a stream that is not open answers `ended`.
public struct CancelStreamRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// `applied`, or `ended` for a stream that was not open.
        public var outcome: String
    }

    public static let command = "cancel-stream"
    public static var requiredCapability: String? { DaemonCapabilities.attachStreams }

    public init() {}
}
