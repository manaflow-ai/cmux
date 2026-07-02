import Foundation

struct WorkspacePullRequestGraphQLRepository: Decodable, Sendable {
    let pullRequests: WorkspacePullRequestGraphQLPullRequestConnection?
    let aliasedPullRequests: [WorkspacePullRequestGraphQLPullRequestNode]

    var nodes: [WorkspacePullRequestGraphQLPullRequestNode?] {
        (pullRequests?.nodes ?? []) + aliasedPullRequests.map(Optional.some)
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case pullRequests
    }

    init(from decoder: any Decoder) throws {
        let fixedContainer = try decoder.container(keyedBy: CodingKeys.self)
        self.pullRequests = try fixedContainer.decodeIfPresent(
            WorkspacePullRequestGraphQLPullRequestConnection.self,
            forKey: .pullRequests
        )
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.aliasedPullRequests = container.allKeys.compactMap { key in
            guard key.stringValue.hasPrefix("pr"),
                  key.stringValue.dropFirst(2).allSatisfy(\.isNumber) else {
                return nil
            }
            // Tolerate a single malformed alias (e.g. a PR closed or renamed
            // mid-fetch returns `null`) so one bad node doesn't drop CI status
            // for the rest of the batch; the affected PR falls back to `.neutral`.
            return try? container.decodeIfPresent(
                WorkspacePullRequestGraphQLPullRequestNode.self,
                forKey: key
            )
        }
    }
}
