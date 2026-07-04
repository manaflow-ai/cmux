public import Foundation

/// Linear adapter backed by the Linear GraphQL API.
public struct LinearIssueSourceAdapter: IssueSourceAdapter {
    public let sourceID: String
    public let displayName: String

    private let teamKey: String
    private let apiKeyEnvVar: String
    private let transport: any IssueInboxHTTPTransport
    private let environment: [String: String]
    private let dateParser: IssueInboxDateParsing

    /// Creates a Linear issue source adapter.
    ///
    /// - Parameters:
    ///   - config: Source configuration with a Linear team key.
    ///   - transport: HTTP transport used for tests and production requests.
    ///   - environment: Environment used for the configured API key variable.
    ///   - dateParser: Provider timestamp parser.
    /// - Throws: ``IssueSourceError/invalidConfiguration(_:)`` when `teamKey` is absent.
    public init(
        config: IssueInboxSourceConfig,
        transport: any IssueInboxHTTPTransport = URLSessionIssueInboxHTTPTransport(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        dateParser: IssueInboxDateParsing = IssueInboxDateParsing()
    ) throws {
        guard config.type == .linear,
              let teamKey = config.teamKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamKey.isEmpty else {
            throw IssueSourceError.invalidConfiguration("Linear issue source requires teamKey.")
        }
        self.teamKey = teamKey
        self.apiKeyEnvVar = config.apiKeyEnvVar?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "LINEAR_API_KEY"
        self.sourceID = "linear:\(teamKey)"
        self.displayName = config.displayName
        self.transport = transport
        self.environment = environment
        self.dateParser = dateParser
    }

    public func fetchIssues() async throws -> [IssueInboxItem] {
        let token = environment[apiKeyEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw IssueSourceError.missingCredentials(provider: .linear, envVar: apiKeyEnvVar)
        }
        guard let url = URL(string: "https://api.linear.app/graphql") else {
            throw IssueSourceError.invalidConfiguration("Invalid Linear API URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": Self.query,
            "variables": ["teamKey": teamKey],
        ])

        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw IssueSourceError.httpStatus(provider: .linear, statusCode: response.statusCode)
        }
        do {
            let decoded = try JSONDecoder().decode(LinearGraphQLResponse.self, from: data)
            if let message = decoded.errors?.first?.message {
                throw IssueSourceError.providerMessage(provider: .linear, message: message)
            }
            return try (decoded.data?.issues.nodes ?? [])
                .map(issueItem(from:))
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch let error as IssueSourceError {
            throw error
        } catch {
            throw IssueSourceError.decoding(provider: .linear, message: String(describing: error))
        }
    }

    private func issueItem(from node: LinearIssueNode) throws -> IssueInboxItem {
        guard let url = URL(string: node.url) else {
            throw IssueSourceError.decoding(provider: .linear, message: "Invalid issue URL for \(node.identifier).")
        }
        guard let updatedAt = dateParser.date(from: node.updatedAt) else {
            throw IssueSourceError.decoding(provider: .linear, message: "Invalid updatedAt for \(node.identifier).")
        }
        let rawState = node.state.type?.nilIfEmpty ?? node.state.name.nilIfEmpty
        return IssueInboxItem(
            id: "linear:\(teamKey):\(node.identifier)",
            provider: .linear,
            sourceURL: url,
            title: node.title,
            status: Self.status(for: rawState),
            providerState: rawState,
            updatedAt: updatedAt,
            repoOrProject: teamKey,
            number: node.identifier,
            assignees: node.assignee.map { [$0.name] } ?? [],
            labels: node.labels.nodes.map(\.name).filter { !$0.isEmpty }
        )
    }

    private static func status(for rawState: String?) -> IssueStatus {
        switch rawState?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "canceled", "cancelled":
            return .closed
        default:
            return .open
        }
    }

    private static let query = """
    query IssueInboxIssues($teamKey: String!) {
      issues(
        filter: { team: { key: { eq: $teamKey } } }
        first: 100
        orderBy: updatedAt
      ) {
        nodes {
          identifier
          title
          url
          updatedAt
          state {
            name
            type
          }
          assignee {
            name
          }
          labels {
            nodes {
              name
            }
          }
        }
      }
    }
    """
}

private struct LinearGraphQLResponse: Decodable {
    var data: LinearGraphQLData?
    var errors: [LinearGraphQLError]?
}

private struct LinearGraphQLData: Decodable {
    var issues: LinearIssueConnection
}

private struct LinearIssueConnection: Decodable {
    var nodes: [LinearIssueNode]
}

private struct LinearIssueNode: Decodable {
    var identifier: String
    var title: String
    var url: String
    var updatedAt: String
    var state: LinearIssueState
    var assignee: LinearIssueAssignee?
    var labels: LinearIssueLabels
}

private struct LinearIssueState: Decodable {
    var name: String
    var type: String?
}

private struct LinearIssueAssignee: Decodable {
    var name: String
}

private struct LinearIssueLabels: Decodable {
    var nodes: [LinearIssueLabel]
}

private struct LinearIssueLabel: Decodable {
    var name: String
}

private struct LinearGraphQLError: Decodable {
    var message: String
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
