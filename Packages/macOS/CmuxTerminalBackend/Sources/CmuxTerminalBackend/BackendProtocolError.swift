internal import Foundation

/// Failures enforced by the terminal-backend protocol client and models.
public enum BackendProtocolError: Error, Equatable, Sendable {
    /// A transport or protocol client was connected more than once.
    case alreadyConnected

    /// An operation required an active connection.
    case notConnected

    /// The backend connection closed before the operation completed.
    case connectionClosed

    /// The monotonically increasing request identifier cannot advance safely.
    case requestIDExhausted

    /// A message did not conform to the expected protocol schema.
    case malformedMessage

    /// A message exceeded the configured byte limit.
    case oversizedMessage(limit: Int)

    /// The bounded transport write queue could not retain another complete frame.
    case writeQueueOverflow(maximumMessages: Int, maximumBytes: Int)

    /// Credential sources on the same kernel socket disagreed about the peer.
    case peerIdentityMismatch

    /// The backend rejected an operation with the provided message.
    case server(String)

    /// The bounded event stream dropped an event at the provided capacity.
    case eventBufferOverflow(capacity: Int)

    /// Canonical topology validation failed with the provided explanation.
    case invalidTopology(String)

    /// The client and backend protocol ranges do not overlap.
    case incompatibleProtocol(client: ClosedRange<UInt32>, server: ClosedRange<UInt32>)

    /// The backend did not advertise all required capabilities.
    case missingCapabilities(Set<String>)

    /// The backend identified itself as an unexpected application.
    case unexpectedApplication(String)

    /// A mutation was rejected locally because this connection is diagnostic-only.
    case mutationUnavailableInReadOnlyMode(
        command: String,
        compatibility: BackendReadOnlyCompatibility
    )
}
