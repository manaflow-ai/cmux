/// Pull-request state reported for a remote workspace.
public struct MobileWorkspacePullRequestState: Decodable, Sendable, Equatable {
    /// The pull-request number.
    public let number: Int
    /// The pull-request lifecycle.
    public let state: MobileWorkspacePullRequestLifecycle
    /// The aggregate CI state known to the host.
    public let ciStatus: MobileWorkspaceCIStatus
    /// The pull-request URL, when the host supplied it.
    public let url: String?
    /// The repository or provider label shown by the host.
    public let label: String?
    /// The normalized head branch, when known.
    public let branch: String?
    /// Whether the host considers this row stale because it came from an inactive panel.
    public let isStale: Bool

    private enum CodingKeys: String, CodingKey {
        case number
        case state
        case ciStatus = "ci_status"
        case url
        case label
        case branch
        case isStale = "is_stale"
    }

    /// Decodes pull-request state, defaulting absent CI data to ``MobileWorkspaceCIStatus/unknown``.
    /// - Parameter decoder: The decoder for the pull-request object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        state = try container.decode(MobileWorkspacePullRequestLifecycle.self, forKey: .state)
        ciStatus = try container.decodeIfPresent(MobileWorkspaceCIStatus.self, forKey: .ciStatus) ?? .unknown
        url = try container.decodeIfPresent(String.self, forKey: .url)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
    }
}
