public import Foundation

/// Connection-owned lease for one canonical browser whose runtime lives in Swift.
public struct BackendFrontendNativeBrowserClaimReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let daemonInstanceID: DaemonInstanceID
    public let sessionID: SessionID
    public let surfaceID: SurfaceID
    public let ownerGeneration: UInt64
    /// Private runtime state returned only across the connection-owned claim.
    /// Canonical topology and durable state never contain this value.
    public let sourceURL: URL?
    public let replayed: Bool

    public var authority: BackendAuthority {
        BackendAuthority(
            daemonInstanceID: daemonInstanceID,
            sessionID: sessionID
        )
    }

    public init(
        requestID: UUID,
        daemonInstanceID: DaemonInstanceID,
        sessionID: SessionID,
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        sourceURL: URL?,
        replayed: Bool
    ) {
        self.requestID = requestID
        self.daemonInstanceID = daemonInstanceID
        self.sessionID = sessionID
        self.surfaceID = surfaceID
        self.ownerGeneration = ownerGeneration
        self.sourceURL = sourceURL
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case surfaceID = "surface_uuid"
        case ownerGeneration = "owner_generation"
        case sourceURL = "source_url"
        case replayed
    }
}

/// Acknowledges one generation-fenced, connection-private source update.
/// The source itself is deliberately omitted from the receipt.
public struct BackendFrontendNativeBrowserSourceReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let daemonInstanceID: DaemonInstanceID
    public let sessionID: SessionID
    public let surfaceID: SurfaceID
    public let ownerGeneration: UInt64
    public let replayed: Bool

    public var authority: BackendAuthority {
        BackendAuthority(
            daemonInstanceID: daemonInstanceID,
            sessionID: sessionID
        )
    }

    public init(
        requestID: UUID,
        daemonInstanceID: DaemonInstanceID,
        sessionID: SessionID,
        surfaceID: SurfaceID,
        ownerGeneration: UInt64,
        replayed: Bool
    ) {
        self.requestID = requestID
        self.daemonInstanceID = daemonInstanceID
        self.sessionID = sessionID
        self.surfaceID = surfaceID
        self.ownerGeneration = ownerGeneration
        self.replayed = replayed
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case daemonInstanceID = "daemon_instance_id"
        case sessionID = "session_id"
        case surfaceID = "surface_uuid"
        case ownerGeneration = "owner_generation"
        case replayed
    }
}
