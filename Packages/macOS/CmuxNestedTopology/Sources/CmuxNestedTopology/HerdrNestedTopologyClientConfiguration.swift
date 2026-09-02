public import Foundation

/// Configuration for ``HerdrNestedTopologyClient``.
public struct HerdrNestedTopologyClientConfiguration: Hashable, Sendable {
    /// Absolute path to the local Herdr Unix-domain socket.
    public var socketPath: String
    /// Attachment that will own decoded snapshots.
    public var attachmentID: UUID
    /// Host cmux stable surface identity for decoded snapshots.
    public var hostStableSurfaceID: UUID
    /// Deadline for establishing a socket connection.
    public var connectTimeout: Duration
    /// Deadline for a single request/response exchange after connect.
    public var requestTimeout: Duration
    /// Maximum idle gap tolerated on the event subscription socket before reconnecting.
    public var eventIdleTimeout: Duration
    /// Maximum UTF-8 bytes accepted for one newline-delimited JSON line.
    ///
    /// Kept below Herdr's 1 MiB initial-request bound.
    public var maxLineUTF8ByteCount: Int
    /// Maximum UTF-8 bytes accepted for a decoded `session.snapshot` result object.
    public var maxSnapshotUTF8ByteCount: Int
    /// Maximum UTF-8 bytes accepted for one pushed event object.
    public var maxEventUTF8ByteCount: Int
    /// Initial reconnect backoff used by ``HerdrNestedTopologyClient/events()``.
    public var reconnectInitialBackoff: Duration
    /// Maximum reconnect backoff used by ``HerdrNestedTopologyClient/events()``.
    public var reconnectMaxBackoff: Duration
    /// Topology validation limits applied after wire decoding.
    public var topologyLimits: NestedTopologyLimits

    /// Creates a Herdr client configuration with production defaults.
    public init(
        socketPath: String,
        attachmentID: UUID,
        hostStableSurfaceID: UUID,
        connectTimeout: Duration = .seconds(5),
        requestTimeout: Duration = .seconds(5),
        eventIdleTimeout: Duration = .seconds(120),
        maxLineUTF8ByteCount: Int = 512 * 1024,
        maxSnapshotUTF8ByteCount: Int = 512 * 1024,
        maxEventUTF8ByteCount: Int = 256 * 1024,
        reconnectInitialBackoff: Duration = .milliseconds(100),
        reconnectMaxBackoff: Duration = .seconds(5),
        topologyLimits: NestedTopologyLimits = .default
    ) {
        self.socketPath = socketPath
        self.attachmentID = attachmentID
        self.hostStableSurfaceID = hostStableSurfaceID
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.eventIdleTimeout = eventIdleTimeout
        self.maxLineUTF8ByteCount = maxLineUTF8ByteCount
        self.maxSnapshotUTF8ByteCount = maxSnapshotUTF8ByteCount
        self.maxEventUTF8ByteCount = maxEventUTF8ByteCount
        self.reconnectInitialBackoff = reconnectInitialBackoff
        self.reconnectMaxBackoff = reconnectMaxBackoff
        self.topologyLimits = topologyLimits
    }
}
