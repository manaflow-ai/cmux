import CmuxNextCompat
public import Foundation

/// The app's own GitHub calls (the pull request page, its checks, merge and re-run, the PR chip's
/// merge and review threads, Create PR's lookups): each is one acpmux `_acpmux/github_rest` op
/// (acpmux `github_rest_op.rs`, op table cmux-host `github_rest.rs`). The daemon runs it with a
/// cmux GitHub App token minted for that one repository when the person is signed in to cmux, else
/// with their own `gh`; neither needs a `gh` login here. This is only the wire.
public nonisolated struct AgentPaneGitHubREST {
    public nonisolated init() {}
    /// One op's answer.
    public struct Answer: Equatable, Sendable {
        /// GitHub took it (a 2xx, and a GraphQL answer with data).
        public var ok: Bool
        public var status: Int?
        /// GitHub's answer, bounded by the daemon.
        public var body: Data
        /// Which login ran: `app` or `keyring`; nil when nothing reached GitHub.
        public var source: String?
        /// Why it did not work, in words for the page (GitHub's own, or the daemon's).
        public var message: String?
        /// The daemon's reason word, e.g. `github.not_connected`.
        public var reason: String?

        public init(ok: Bool, status: Int? = nil, body: Data = Data(), source: String? = nil, message: String? = nil, reason: String? = nil) {
            self.ok = ok
            self.status = status
            self.body = body
            self.source = source
            self.message = message
            self.reason = reason
        }

        /// The daemon's reply (`{ok, status, body, source, message}`).
        public init(reply: [String: Any]) {
            self.init(ok: reply["ok"] as? Bool ?? false, status: reply["status"] as? Int,
                      body: Data((reply["body"] as? String ?? "").utf8), source: reply["source"] as? String,
                      message: reply["message"] as? String)
        }

        /// The answer as a JSON object, nil when it is not one or GitHub refused.
        public var object: [String: Any]? {
            guard ok else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }

        /// GraphQL's `data` object.
        public var data: [String: Any]? { object?["data"] as? [String: Any] }

        /// Words for a refusal: GitHub's or the daemon's, else a plain one.
        public var refusal: String { message.flatMap { $0.isEmpty ? nil : $0 } ?? AgentPaneGitHubREST.unreachableMessage }
    }

    /// Runs `params` (`{op, repo, ...}`) as one `_acpmux/github_rest` call on this app's acpmux,
    /// over a line acpmux took the person proof of (the daemon mints with the sign-in the app lent
    /// it, CmuxNextHomeEngine GitHubAppLease); an answer with `ok: false` when there is none.
    public static func call(_ params: [String: any Sendable]) async -> Answer {
        guard let environment = await AcpmuxEnvironment.resolvedApp(build: BuildIdentity(bundle: .main), mock: false) else {
            return Answer(ok: false, message: unreachableMessage)
        }
        return await call(params, on: environment)
    }

    @MainActor private static func call(_ params: [String: any Sendable], on environment: AcpmuxEnvironment) async -> Answer {
        guard let line = await AcpmuxPersonLine.open(environment) else { return Answer(ok: false, message: unreachableMessage) }
        defer { line.close() }
        guard line.isPerson else { return Answer(ok: false, message: unreachableMessage) }
        guard let reply = await line.call("_acpmux/github_rest", plain(params)) else {
            return Answer(ok: false, message: line.lastError.flatMap { $0.isEmpty ? nil : $0 } ?? unreachableMessage,
                          reason: line.lastErrorReason)
        }
        return Answer(reply: reply)
    }

    /// `params` with plain JSON values (nested objects too), for the line's JSON encoding.
    private static func plain(_ params: [String: any Sendable]) -> [String: Any] {
        params.mapValues { value -> Any in
            if let nested = value as? [String: any Sendable] { return plain(nested) }
            return value
        }
    }

    /// A read-only GraphQL query on `repository` (`owner/name`) with `variables`.
    public static func graphql(_ repository: String, _ query: String, _ variables: [String: any Sendable],
                               scope: String = "pulls") async -> Answer {
        await call(["op": "graphql", "repo": repository, "query": query, "variables": variables, "scope": scope])
    }

    /// `GET repos/{repository}/{path}`; `tail` keeps only the answer's last bytes.
    public static func get(_ repository: String, _ path: String, tail: Int? = nil) async -> Answer {
        var params: [String: any Sendable] = ["op": "get", "repo": repository, "path": path]
        if let tail { params["tail"] = tail }
        return await call(params)
    }

    /// `owner/name` and the number of a pull request address (`https://github.com/o/n/pull/N`).
    public static func pullRequest(_ url: String) -> (repository: String, number: Int)? {
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host?.lowercased() == "github.com" else { return nil }
        let parts = parsed.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
              let repository = AgentPaneGitHubRepository.parse("https://github.com/\(parts[0])/\(parts[1])") else { return nil }
        return (repository, number)
    }

    /// Nothing answered (no acpmux line yet, or it went away).
    public static var unreachableMessage: String { "cmux couldn't reach GitHub. Try again in a moment." }
}
