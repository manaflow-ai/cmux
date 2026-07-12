public import Foundation

/// Patch payload returned by the paired Mac's `mobile.diff.load` RPC.
public struct MobileDiffDocument: Decodable, Equatable, Sendable {
    public let patch: String
    public let repositoryRoot: String
    public let title: String

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

    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
