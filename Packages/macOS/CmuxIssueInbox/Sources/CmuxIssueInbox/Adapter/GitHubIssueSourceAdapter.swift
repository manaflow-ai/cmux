public import CmuxFoundation
public import Foundation

/// GitHub Issues adapter backed by the REST issues endpoint.
public struct GitHubIssueSourceAdapter: IssueSourceAdapter {
    public let sourceID: String
    public let displayName: String

    private let repo: String
    private let transport: any IssueInboxHTTPTransport
    private let commandRunner: any CommandRunning
    private let environment: [String: String]
    private let currentDirectory: String
    private let dateParser: IssueInboxDateParsing

    /// Creates a GitHub issue source adapter.
    ///
    /// - Parameters:
    ///   - config: Source configuration with a GitHub repo.
    ///   - transport: HTTP transport used for tests and production requests.
    ///   - commandRunner: Runner used for `gh auth token` fallback.
    ///   - environment: Environment used for `GH_TOKEN` and `GITHUB_TOKEN`.
    ///   - currentDirectory: Working directory for `gh auth token`.
    ///   - dateParser: Provider timestamp parser.
    /// - Throws: ``IssueSourceError/invalidConfiguration(_:)`` when `repo` is absent.
    public init(
        config: IssueInboxSourceConfig,
        transport: any IssueInboxHTTPTransport = URLSessionIssueInboxHTTPTransport(),
        commandRunner: any CommandRunning = CommandRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        dateParser: IssueInboxDateParsing = IssueInboxDateParsing()
    ) throws {
        guard config.type == .github,
              let repo = config.repo?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repo.isEmpty else {
            throw IssueSourceError.invalidConfiguration("GitHub issue source requires repo.")
        }
        self.repo = repo
        self.sourceID = "github:\(repo)"
        self.displayName = config.displayName
        self.transport = transport
        self.commandRunner = commandRunner
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.dateParser = dateParser
    }

    public func fetchIssues() async throws -> [IssueInboxItem] {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/issues?state=open&per_page=100") else {
            throw IssueSourceError.invalidConfiguration("Invalid GitHub repo '\(repo)'.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("cmux-issue-inbox", forHTTPHeaderField: "User-Agent")
        if let authHeader = await authHeaderValue() {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw IssueSourceError.httpStatus(provider: .github, statusCode: response.statusCode)
        }
        do {
            let decoded = try JSONDecoder().decode([GitHubIssueRESTItem].self, from: data)
            return try decoded.compactMap(issueItem(from:))
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch let error as IssueSourceError {
            throw error
        } catch {
            throw IssueSourceError.decoding(provider: .github, message: String(describing: error))
        }
    }

    private func issueItem(from item: GitHubIssueRESTItem) throws -> IssueInboxItem? {
        guard item.pullRequest == nil else { return nil }
        guard let url = URL(string: item.htmlURL) else {
            throw IssueSourceError.decoding(provider: .github, message: "Invalid issue URL for #\(item.number).")
        }
        guard let updatedAt = dateParser.date(from: item.updatedAt) else {
            throw IssueSourceError.decoding(provider: .github, message: "Invalid updated_at for #\(item.number).")
        }
        let state = item.state.lowercased() == "closed" ? IssueStatus.closed : .open
        return IssueInboxItem(
            id: "github:\(repo):\(item.number)",
            provider: .github,
            sourceURL: url,
            title: item.title,
            status: state,
            providerState: item.state,
            updatedAt: updatedAt,
            repoOrProject: repo,
            number: String(item.number),
            assignees: item.assignees.map(\.login).filter { !$0.isEmpty },
            labels: item.labels.map(\.name).filter { !$0.isEmpty }
        )
    }

    private func authHeaderValue() async -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            let trimmed = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return "Bearer \(trimmed)"
            }
        }
        let token = await commandRunner.runStandardOutput(
            directory: currentDirectory,
            executable: "gh",
            arguments: ["auth", "token"],
            timeout: 5.0
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { return nil }
        return "Bearer \(token)"
    }
}

private struct GitHubIssueRESTItem: Decodable {
    var number: Int
    var state: String
    var htmlURL: String
    var title: String
    var updatedAt: String
    var assignees: [GitHubIssueRESTUser]
    var labels: [GitHubIssueRESTLabel]
    var pullRequest: GitHubIssueRESTPullRequest?

    private enum CodingKeys: String, CodingKey {
        case number
        case state
        case htmlURL = "html_url"
        case title
        case updatedAt = "updated_at"
        case assignees
        case labels
        case pullRequest = "pull_request"
    }
}

private struct GitHubIssueRESTUser: Decodable {
    var login: String
}

private struct GitHubIssueRESTLabel: Decodable {
    var name: String
}

private struct GitHubIssueRESTPullRequest: Decodable {}
