public import Foundation

/// Patch payload returned by the paired Mac's `mobile.diff.load` RPC.
public struct MobileDiffDocument: Decodable, Equatable, Sendable {
    /// The complete Git patch rendered by the mobile web view.
    public let patch: String
    /// The paired Mac's canonical repository root.
    public let repositoryRoot: String
    /// The native title shown for the source workspace.
    public let title: String

    /// Creates a mobile diff document.
    /// - Parameters:
    ///   - patch: Complete Git patch text.
    ///   - repositoryRoot: Canonical repository root on the paired Mac.
    ///   - title: User-facing source title.
    public init(patch: String, repositoryRoot: String, title: String) {
        self.patch = patch
        self.repositoryRoot = repositoryRoot
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case patch
        case repositoryRoot = "repository_root"
        case title
    }

    /// Decodes a document from the typed `mobile.diff.load` response.
    /// - Parameter data: JSON response bytes from the paired Mac.
    public init(decoding data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }
}
