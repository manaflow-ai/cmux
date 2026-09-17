import Foundation

/// One paginated query for the same PR commit rollup that GitHub displays.
struct PullRequestChecksQuery {
    let owner: String
    let repository: String
    let number: Int
    let cursor: String?

    func encodedBody() throws -> Data {
        let query = """
        query SidebarPullRequestChecks($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              mergeable mergeStateStatus
              commits(last: 1) {
                nodes { commit {
                  oid
                  statusCheckRollup { contexts(first: 100, after: $cursor) {
                    pageInfo { hasNextPage endCursor }
                    nodes {
                      __typename
                      ... on CheckRun {
                        id databaseId name status conclusion detailsUrl startedAt
                        checkSuite { app { id } workflowRun { event workflow { id } } }
                      }
                      ... on StatusContext { id context state targetUrl createdAt }
                    }
                  } }
                } }
              }
            }
          }
        }
        """
        return try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["owner": owner, "repo": repository, "number": number, "cursor": cursor as Any? ?? NSNull()]
        ], options: .sortedKeys)
    }
}
