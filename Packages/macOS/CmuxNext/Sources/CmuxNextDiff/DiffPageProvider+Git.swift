public import CmuxNextAgentPane
public import CmuxNextDaemonService
import CmuxNextPages
public import CmuxNextSettings
import CryptoKit
import Foundation

/// Runs the diff tab's git reads and writes (cx-ueuc8) in a repository: the agent pane's git
/// link and staging, so the viewer stages, commits and pushes as the chat's changes view does.
public protocol DiffGitRunning: AnyObject {
    /// The session host's `git.status` of `repository`.
    func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue
    /// The session host's `git.diff` of `repository` in `scope`, with each file's patch or only its counts.
    func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue
    /// The session host's commit or push in `repository`, under the request's key.
    func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue
    /// `git add` / `git restore --staged` (or one hunk) in `repository`; nil on success, else
    /// why it failed.
    func stage(_ request: AgentPaneGitStage, in repository: String) async -> String?
    /// The session host's `git.checkpoint.diff` of `repository`, checkpoint `from` against `to`,
    /// with each file's patch (a chat turn, Last turn).
    func checkpointDiff(_ repository: String, from: String, to: String) async throws(AgentPaneGitFailure) -> JSONValue
}

extension DiffGitRunning {
    /// A git without checkpoint reads (tests): every turn read fails.
    public func checkpointDiff(_ repository: String, from: String, to: String) async throws(AgentPaneGitFailure) -> JSONValue {
        throw AgentPaneGitFailure.failed
    }
}

/// The diff tab's Stage, Commit and Push (cx-ueuc8): `cmux.diff.git.status {}`,
/// `cmux.diff.git.diff {scope}` (the files only, for Commit's "Include new files"),
/// `cmux.diff.git.fingerprint {scope}` (a hash of the scope's diff, patches included, so the
/// viewer sees an agent's edit without moving the diff over the bridge; cx-9ce.34),
/// `cmux.diff.git.commit` and `cmux.diff.git.push` with the changes view's params (no
/// `session_id`), and `cmux.diff.git.stage`, `.unstage`, `.stageHunk`, `.unstageHunk` with
/// `{paths, hunk?}`. Each runs in the tab's own repository, the one its grant covers: a `cwd`
/// or `path` the page sends is replaced, so a page can never point a write at another folder.
/// Writes need a real click or key in the page (``PageCallContext/userGesture``).
extension DiffPageProvider {
    static let gitOps: Set<String> = [
        "cmux.diff.git.status", "cmux.diff.git.diff", "cmux.diff.git.fingerprint", "cmux.diff.git.commit", "cmux.diff.git.push",
        "cmux.diff.git.stage", "cmux.diff.git.unstage", "cmux.diff.git.stageHunk", "cmux.diff.git.unstageHunk",
    ]
    /// The session the writes name: the diff tab has no chat, and the session host keys only on
    /// the page's idempotency key.
    static let gitSession = "diff-tab"

    /// Answers a git op; nil for any other op.
    func gitCall(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue? {
        guard Self.gitOps.contains(op) else { return nil }
        guard let git else { throw PageError.unknownOp(op) }
        let repository = try await gitRepository()
        let method = "git." + op.dropFirst("cmux.diff.git.".count)
        let scope = params["scope"]?.stringValue.flatMap(AgentPaneGitScope.init(rawValue:)) ?? .uncommitted
        do {
            switch method {
            case "git.status": return try await git.status(repository)
            case "git.diff": return try await git.diff(repository, scope: scope, includePatch: false)
            case "git.fingerprint": return ["fingerprint": .string(Self.fingerprint(try await git.diff(repository, scope: scope, includePatch: true)))]
            default: break
            }
        } catch {
            throw Self.pageError(error)
        }
        guard context.userGesture else {
            throw PageError(code: "transport.gesture_required", message: AgentPaneGitStage.needsGestureMessage)
        }
        var fields = (params.objectValue ?? [:]).mapValues(\.foundationObject)
        if method == "git.commit" || method == "git.push" {
            fields["session_id"] = Self.gitSession
            fields["cwd"] = nil
            fields["path"] = nil
            guard let request = AgentPaneGitWrite(method: method, params: fields) else {
                throw PageError.invalidParams("The app refused the request.")
            }
            do {
                return try await git.write(request, in: repository)
            } catch {
                throw Self.pageError(error)
            }
        }
        fields["cwd"] = repository
        guard let request = AgentPaneGitStage(method: method, params: fields) else {
            throw PageError.invalidParams(AgentPaneGitStage.invalidMessage)
        }
        if let message = await git.stage(request, in: repository) {
            throw PageError(code: "git.failed", message: message)
        }
        return ["ok": true]
    }

    /// `config` listing the git ops, when this tab serves them.
    func withGit(_ config: JSONValue) -> JSONValue {
        guard git != nil, case .object(var members) = config, members["pick"] == nil else { return config }
        let ops = Self.gitOps.union(git is any DiffGitReverting ? Self.revertOps : [])
        members["ops"] = .array((members["ops"]?.arrayValue ?? []) + ops.sorted().map(JSONValue.string))
        return .object(members)
    }

    /// SHA-256 of the diff's compact JSON, hex.
    static func fingerprint(_ diff: JSONValue) -> String {
        SHA256.hash(data: Data(diff.compactText.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The repository the tab's grant covers.
    func gitRepository() async throws -> String {
        guard let ready else { throw PageError(code: "sidecarUnavailable", message: "No repository is open") }
        do {
            return try await ready.value.grant.repository
        } catch let failure as DiffTabFailure {
            throw PageError(code: "sidecarUnavailable", message: failure.message)
        }
    }

    /// The page's failure for a session host or native git failure, its details kept so the
    /// changes view reads the reason and git's output.
    static func pageError(_ failure: AgentPaneGitFailure) -> PageError {
        var details = failure.details.flatMap { try? JSONValue.parse($0) }
        if failure.origin == .native {
            var object = details?.objectValue ?? [:]
            object["origin"] = "native"
            details = .object(object)
        }
        return PageError(code: failure.code, message: failure.code, retryable: failure.retryable ?? false, details: details)
    }
}

/// The running app's diff git: the agent pane's local git link and its staging.
public final class DiffAgentGit: DiffGitRunning {
    private let link: AgentPaneGitLink

    public init(link: AgentPaneGitLink) {
        self.link = link
    }

    public func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue {
        try Self.parse(try await link.read(.status(cwd: repository)))
    }

    public func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue {
        try Self.parse(try await link.read(.diff(cwd: repository, scope: scope, includePatch: includePatch)))
    }

    public func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue {
        try Self.parse(try await link.write(request, in: repository))
    }

    public func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? {
        await AgentPaneGitStage.run(request, roots: [repository])
    }

    public func checkpointDiff(_ repository: String, from: String, to: String) async throws(AgentPaneGitFailure) -> JSONValue {
        try Self.parse(try await link.read(.checkpointDiff(cwd: repository, from: from, to: to, includePatch: true)))
    }

    private static func parse(_ data: Data) throws(AgentPaneGitFailure) -> JSONValue {
        guard let value = try? JSONValue.parse(data) else { throw AgentPaneGitFailure.failed }
        return value
    }
}
