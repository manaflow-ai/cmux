public import Foundation

/// One recorded fixture transport operation.
public struct AgentSyncTransportCall: Hashable, Sendable {
    /// The operation kind.
    public enum Kind: Hashable, Sendable {
        /// A request operation.
        case request
        /// A subscribe operation.
        case subscribe
        /// An unsubscribe operation.
        case unsubscribe
    }

    /// The operation kind.
    public let kind: Kind
    /// The RPC method for request operations.
    public let method: String?
    /// The topics for subscription operations.
    public let topics: [String]
    /// Raw request parameters for request operations.
    public let params: Data?

    /// Creates a fixture transport call record.
    /// - Parameters:
    ///   - kind: The operation kind.
    ///   - method: The RPC method for request operations.
    ///   - topics: The topics for subscription operations.
    ///   - params: Raw request parameters for request operations.
    public init(kind: Kind, method: String? = nil, topics: [String] = [], params: Data? = nil) {
        self.kind = kind
        self.method = method
        self.topics = topics
        self.params = params
    }
}
