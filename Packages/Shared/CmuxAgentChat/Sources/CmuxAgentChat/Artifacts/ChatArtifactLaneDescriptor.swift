import Foundation

/// An opaque, short-lived capability for one authorized Iroh artifact transfer.
public struct ChatArtifactLaneDescriptor: Codable, Equatable, Sendable {
    /// Opaque capability presented in the Iroh artifact-lane header.
    public let resourceID: String
    /// File size captured when the Mac authorized the transfer.
    public let totalSize: Int64
    /// Time after which the Mac refuses new lane claims.
    public let expiresAt: Date

    public init(resourceID: String, totalSize: Int64, expiresAt: Date) {
        self.resourceID = resourceID
        self.totalSize = totalSize
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case resourceID = "resource_id"
        case totalSize = "total_size"
        case expiresAt = "expires_at"
    }
}
