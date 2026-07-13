import Foundation

/// A requested file whose individual unified diff exceeded the host soft cap.
public struct MobileSyncGitDiffTooLargeFile: Decodable, Sendable {
    /// The repository-relative requested path.
    public let path: String
    /// The UTF-8 byte count of the generated unified diff.
    public let bytes: Int
}
