import Foundation

/// Decodes the GitHub GraphQL response carrying each open PR's
/// `statusCheckRollup.state`, keyed for indexing by head branch.
///
/// One request per repo per cache window returns the rollup for up to 100 open
/// PRs at once — request volume scales with repo count, not PR count.
struct WorkspaceCIStatusGraphQLResponse: Decodable, Sendable {
    struct DataPayload: Decodable, Sendable {
        let repository: Repository?
    }

    struct Repository: Decodable, Sendable {
        let pullRequests: PullRequestConnection
    }

    struct PullRequestConnection: Decodable, Sendable {
        let nodes: [PullRequestNode]
    }

    struct PullRequestNode: Decodable, Sendable {
        let number: Int
        let headRefName: String?
        let commits: CommitConnection
    }

    struct CommitConnection: Decodable, Sendable {
        let nodes: [CommitNode]
    }

    struct CommitNode: Decodable, Sendable {
        let commit: Commit
    }

    struct Commit: Decodable, Sendable {
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable, Sendable {
        let state: String?
    }

    let data: DataPayload?

    /// The GraphQL query string (uses `$owner`/`$name` variables — never string
    /// interpolation — so a slug can't inject into the query).
    ///
    /// Ordered by most-recently-updated so that in a repo with more than 100
    /// open PRs the fetched window covers the active branches workspaces map to
    /// (mirroring the REST `sort=updated&direction=desc` path). The bound is
    /// intentional: one request per repo per cache window must not scale with
    /// open-PR count, so older PRs beyond the window stay neutral until they
    /// re-enter it. A workspace branch outside the window still gets its PR via
    /// the REST per-branch lookup; only its CI glyph degrades to neutral.
    static let query = """
    query($owner: String!, $name: String!) { \
    repository(owner: $owner, name: $name) { \
    pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { \
    number headRefName \
    commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } \
    } } } }
    """

    /// Folds the response into a `[normalizedBranch: WorkspaceCIStatus]` map,
    /// using the same branch normalization as the PR map so keys line up.
    func ciStatusByNormalizedBranch() -> [String: WorkspaceCIStatus] {
        var result: [String: WorkspaceCIStatus] = [:]
        for node in data?.repository?.pullRequests.nodes ?? [] {
            guard let branch = GitMetadataService.normalizedBranchName(node.headRefName) else {
                continue
            }
            let rollupState = node.commits.nodes.first?.commit.statusCheckRollup?.state
            result[branch] = WorkspaceCIStatus(rollupState: rollupState)
        }
        return result
    }
}
