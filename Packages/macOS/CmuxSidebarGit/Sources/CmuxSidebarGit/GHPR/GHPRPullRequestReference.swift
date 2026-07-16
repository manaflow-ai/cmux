public import Foundation

/// Repository and pull-request number accepted by PRDashboard's `pr` command.
public struct GHPRPullRequestReference: Equatable, Hashable, Sendable {
    public let repository: String
    public let number: Int

    public init(repository: String, number: Int) {
        self.repository = repository
        self.number = number
    }

    /// Extracts `owner/repository` from a GitHub-style pull-request URL.
    public init?(pullRequestURL: URL, number: Int) {
        let components = pullRequestURL.pathComponents.filter { $0 != "/" }
        guard components.count >= 4,
              components[2] == "pull",
              Int(components[3]) == number else {
            return nil
        }
        let owner = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let repositoryName = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !repositoryName.isEmpty else { return nil }
        self.init(repository: "\(owner)/\(repositoryName)", number: number)
    }
}
