public import Foundation

/// A detailed check row returned by `gh pr checks <number> --json name,state,link`.
public struct GitHubPullRequestCheck: Decodable, Equatable, Hashable, Identifiable, Sendable {
    /// The check name shown by GitHub.
    public let name: String
    /// The raw GitHub CLI check state.
    public let state: String
    /// The check-run URL, when GitHub reports one.
    public let link: URL?

    /// A stable value identity for SwiftUI rows.
    public var id: String {
        "\(name)|\(link?.absoluteString ?? "")"
    }

    /// The normalized presentation state.
    public var presentationState: PullRequestCheckState {
        switch state.uppercased() {
        case "SUCCESS":
            return .success
        case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR":
            return .failure
        case "PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED":
            return .pending
        default:
            return .neutral
        }
    }

    /// Creates a detailed pull-request check.
    /// - Parameters:
    ///   - name: The check name.
    ///   - state: The raw GitHub CLI check state.
    ///   - link: The check-run URL.
    public init(name: String, state: String, link: URL?) {
        self.name = name
        self.state = state
        self.link = link
    }
}
