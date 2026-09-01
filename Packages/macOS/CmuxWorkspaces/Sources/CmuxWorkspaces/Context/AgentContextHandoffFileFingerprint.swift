public import Foundation

/// Compact identity and content fingerprint for one descriptor-bound handoff
/// file snapshot.
///
/// The fingerprint is intentionally opaque to callers. It lets a later
/// verification compare the exact file observed before a preservation request
/// without retaining up to the one-megabyte handoff payload in coordinator
/// state.
public struct AgentContextHandoffFileFingerprint: Equatable, Sendable {
    /// Device identity captured from the descriptor, when available.
    public let deviceID: UInt64?
    /// Inode/file identity captured from the descriptor, when available.
    public let fileID: UInt64?
    /// Byte size captured from the descriptor.
    public let size: Int
    /// SHA-256 digest of the bounded bytes captured from the descriptor.
    public let contentDigest: Data

    /// Creates a descriptor/content fingerprint.
    ///
    /// - Parameters:
    ///   - deviceID: Filesystem device identity, when available.
    ///   - fileID: Filesystem inode/file identity, when available.
    ///   - size: Byte size captured for the snapshot.
    ///   - contentDigest: SHA-256 digest of the captured bytes.
    public init(
        deviceID: UInt64?,
        fileID: UInt64?,
        size: Int,
        contentDigest: Data
    ) {
        self.deviceID = deviceID
        self.fileID = fileID
        self.size = size
        self.contentDigest = contentDigest
    }
}
