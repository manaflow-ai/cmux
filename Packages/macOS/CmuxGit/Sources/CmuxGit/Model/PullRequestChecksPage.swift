import Foundation

/// Validates the GraphQL envelope before interpreting a page as complete.
/// Unknown union members and partial GraphQL errors fail closed.
struct PullRequestChecksPage: Sendable {
    let headSHA: String
    let mergeStatus: PullRequestMergeStatus
    let contexts: [PullRequestCheckContext]
    let nextCursor: String?

    init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["errors"] as? [Any] ?? []).isEmpty,
              let payload = root["data"] as? [String: Any],
              let repository = payload["repository"] as? [String: Any],
              let pr = repository["pullRequest"] as? [String: Any],
              let commits = pr["commits"] as? [String: Any],
              let nodes = commits["nodes"] as? [[String: Any]],
              let commit = nodes.first?["commit"] as? [String: Any],
              let sha = commit["oid"] as? String, !sha.isEmpty else { return nil }
        headSHA = sha
        let mergeable: Bool?
        switch pr["mergeable"] as? String {
        case "MERGEABLE": mergeable = true
        case "CONFLICTING": mergeable = false
        default: mergeable = nil
        }
        mergeStatus = PullRequestMergeStatus(mergeable: mergeable, mergeableState: pr["mergeStateStatus"] as? String)
        if commit["statusCheckRollup"] is NSNull {
            contexts = []
            nextCursor = nil
            return
        }
        guard let rollup = commit["statusCheckRollup"] as? [String: Any],
              let connection = rollup["contexts"] as? [String: Any],
              let rawNodes = connection["nodes"] as? [[String: Any]],
              let page = connection["pageInfo"] as? [String: Any],
              let more = page["hasNextPage"] as? Bool else { return nil }
        let decoded = rawNodes.compactMap(PullRequestCheckContext.init)
        guard decoded.count == rawNodes.count else { return nil }
        contexts = decoded
        if more {
            guard let cursor = page["endCursor"] as? String, !cursor.isEmpty else { return nil }
            nextCursor = cursor
        } else {
            nextCursor = nil
        }
    }
}
