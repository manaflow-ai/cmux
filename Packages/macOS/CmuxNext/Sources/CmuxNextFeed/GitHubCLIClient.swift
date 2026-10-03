public import Foundation

/// A GitHub API implementation that uses the user's existing `gh` login.
/// No token is read, copied, or persisted by cmux.
public struct GitHubCLIClient: GitHubFeedAPI {
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

    private func request<Value: Decodable & Sendable>(
        path: String, fields: [String: String], etag: String?, listKey: String? = nil
    ) async throws -> GitHubAPIResponse<[Value]> {
        let executable = executable
        let result = try await Task.detached(priority: .utility) {
            try Self.run(executable: executable, path: path, fields: fields, etag: etag)
        }.value
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

    private static func run(
        executable: String, path: String, fields: [String: String], etag: String?
    ) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        let command = ["gh", "api", "--include", "-X", "GET", path]
            + fields.sorted(by: { $0.key < $1.key }).flatMap { ["-f", "\($0.key)=\($0.value)"] }
        process.arguments = executable == "/usr/bin/env" ? command : Array(command.dropFirst())
        if let etag { process.arguments?.append(contentsOf: ["-H", "If-None-Match: \(etag)"]) }
        process.standardOutput = output
        // Merge stderr into stdout so a noisy `gh` failure cannot deadlock
        // while the parent drains one pipe before the other.
        process.standardError = output
        try process.run()
        // concurrency-allow: this helper runs inside the detached utility task; the pipe is bounded by one gh response.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        // concurrency-allow: detached utility task owns the process and waits only after its output reaches EOF.
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitHubFeedError.cliUnavailable(String(data: data, encoding: .utf8) ?? "gh failed")
        }
        let parsed = Self.parseHTTP(data)
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
