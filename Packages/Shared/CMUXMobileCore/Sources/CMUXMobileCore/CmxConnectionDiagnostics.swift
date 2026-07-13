import Foundation

/// Snapshot metadata describing the route a byte transport is using.
public struct CmxConnectionDiagnostics: Equatable, Sendable {
    /// The transport kind backing the connection, when known.
    public let kind: CmxAttachTransportKind?
    /// The endpoint backing the connection, when known.
    public let endpoint: CmxAttachEndpoint?
    /// The latest round-trip latency in milliseconds, when measured.
    public let rttMilliseconds: Int?

    /// Creates a diagnostics snapshot.
    /// - Parameters:
    ///   - kind: The transport kind backing the connection, when known.
    ///   - endpoint: The endpoint backing the connection, when known.
    ///   - rttMilliseconds: The latest round-trip latency in milliseconds, when measured.
    public init(
        kind: CmxAttachTransportKind?,
        endpoint: CmxAttachEndpoint?,
        rttMilliseconds: Int?
    ) {
        self.kind = kind
        self.endpoint = endpoint
        self.rttMilliseconds = rttMilliseconds
    }
}
