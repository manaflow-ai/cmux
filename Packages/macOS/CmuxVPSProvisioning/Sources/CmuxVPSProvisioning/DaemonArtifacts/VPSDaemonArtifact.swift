public import Foundation

/// A verified local cmuxd-remote binary ready for upload.
public struct VPSDaemonArtifact: Equatable, Sendable {
    /// Local path of the verified binary.
    public var localURL: URL
    /// SHA-256 hex digest of the binary; the executor re-verifies this on the
    /// host after upload.
    public var sha256: String
    /// Daemon version the binary was built as.
    public var version: String

    /// Creates an artifact description.
    public init(localURL: URL, sha256: String, version: String) {
        self.localURL = localURL
        self.sha256 = sha256.lowercased()
        self.version = version
    }
}
