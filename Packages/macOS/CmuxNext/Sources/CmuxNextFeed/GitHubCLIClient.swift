public import Foundation
import CmuxNextWakeups

/// A GitHub API implementation that uses the user's existing `gh` login.
/// No token is read, copied, or persisted by cmux.
///
/// `nonisolated`, and each request `@concurrent`: the feed source that calls it is main-actor, and the
/// `gh` spawn, the HTTP parse and the JSON decode of up to 100 items must never run on the main thread.
public nonisolated struct GitHubCLIClient: GitHubFeedAPI {
    public var executable: String

    public init(executable: String = "/usr/bin/env") {
        self.executable = executable
    }

    public func notifications(etag: String?) async throws -> GitHubAPIResponse<[GitHubNotification]> {
        try await request(path: "notifications", fields: ["per_page": "100"], etag: etag)
    }

    public func reviewRequests(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
        try await request(
            path: "search/issues", fields: ["q": "is:pr is:open review-requested:@me", "per_page": "100"],
            etag: etag, listKey: "items"
        )
    }

    public func failingChecks(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
        try await request(
            path: "search/issues", fields: ["q": "is:pr is:open author:@me status:failure", "per_page": "100"],
            etag: etag, listKey: "items"
        )
    }

    public func assignedWork(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
        try await request(
            path: "search/issues", fields: ["q": "is:open assignee:@me archived:false", "per_page": "50"],
            etag: etag, listKey: "items"
        )
    }

    @concurrent private func request<Value: Decodable & Sendable>(
        path: String, fields: [String: String], etag: String?, listKey: String? = nil
    ) async throws -> GitHubAPIResponse<[Value]> {
        let result = try await Self.run(executable: executable, path: path, fields: fields, etag: etag)
        guard result.status != 304 else {
            return GitHubAPIResponse(value: nil, etag: result.etag, notModified: true)
        }
        guard (200..<300).contains(result.status) else {
            throw GitHubFeedError.commandFailed(result.status, result.body)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if listKey != nil {
            let object = try decoder.decode(GitHubSearchResponse<Value>.self, from: result.body)
            return GitHubAPIResponse(value: object.items, etag: result.etag)
        }
        return GitHubAPIResponse(value: try decoder.decode([Value].self, from: result.body), etag: result.etag)
    }

    private struct CommandResult: Sendable {
        var status: Int
        var etag: String?
        var body: Data
    }

    @concurrent private static func run(
        executable: String, path: String, fields: [String: String], etag: String?
    ) async throws -> CommandResult {
        let command = ["gh", "api", "--include", "-X", "GET", path]
            + fields.sorted(by: { $0.key < $1.key }).flatMap { ["-f", "\($0.key)=\($0.value)"] }
        var arguments = executable == "/usr/bin/env" ? command : Array(command.dropFirst())
        if let etag { arguments.append(contentsOf: ["-H", "If-None-Match: \(etag)"]) }
        // stderr merged into stdout (one pipe, no deadlock on a noisy failure); awaited without a thread.
        let outcome: ProcessOutcome
        do {
            outcome = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: executable), arguments,
                                                                  errorOutput: .merge))
        } catch ProcessFailure.launch(let message) {
            throw GitHubFeedError.cliUnavailable(message)
        }
        guard outcome.status == 0 else {
            throw GitHubFeedError.cliUnavailable(String(data: outcome.output, encoding: .utf8) ?? "gh failed")
        }
        let parsed = Self.parseHTTP(outcome.output)
        return CommandResult(status: parsed.status, etag: parsed.etag, body: parsed.body)
    }

    private static func parseHTTP(_ data: Data) -> (status: Int, etag: String?, body: Data) {
        let separator = Data("\r\n\r\n".utf8)
        let fallback = Data("\n\n".utf8)
        let range = data.range(of: separator) ?? data.range(of: fallback)
        guard let range else { return (200, nil, data) }
        let header = String(decoding: data[..<range.lowerBound], as: UTF8.self)
        let body = Data(data[range.upperBound...])
        let status = header.split(whereSeparator: \.isNewline).first.flatMap { line in
            line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        } ?? 200
        let etag = header.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "etag" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }.last
        return (status, etag, body)
    }
}
