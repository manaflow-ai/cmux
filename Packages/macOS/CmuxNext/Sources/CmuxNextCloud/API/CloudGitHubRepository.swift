public import Foundation

/// A repository returned by the GitHub connector. It contains no credentials or clone URL.
public struct CloudGitHubRepository: Codable, Equatable, Sendable, Identifiable {
    public let owner: String
    public let name: String
    public let isPrivate: Bool
    public let defaultBranch: String

    public var id: String { "\(owner)/\(name)" }

    public init(owner: String, name: String, isPrivate: Bool, defaultBranch: String) {
        self.owner = owner
        self.name = name
        self.isPrivate = isPrivate
        self.defaultBranch = defaultBranch
    }

    private enum CodingKeys: String, CodingKey {
        case owner, name
        case isPrivate = "private"
        case defaultBranch
    }
}
