public import CMUXMobileCore
public import Foundation

/// One independently cancellable raw artifact lane.
public protocol MobileArtifactLaneConnection: Sendable {
    /// Reads at most the requested byte count, or nil after clean EOF.
    func receive(maximumByteCount: Int) async throws -> Data?
    /// Aborts the lane and releases transport resources.
    func close() async
}

/// Opens an artifact lane on the RPC client's already-admitted Iroh peer.
public typealias MobileArtifactLaneProvider = @Sendable (
    _ request: CmxByteTransportRequest,
    _ resourceID: String,
    _ offset: UInt64
) async throws -> any MobileArtifactLaneConnection
