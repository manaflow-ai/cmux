public import Foundation

/// A scope of `git.diff` on the session host (cmux-tui `GitDiffScope`).
public nonisolated enum AgentPaneGitScope: String, CaseIterable, Equatable, Sendable {
    case uncommitted
    case unstaged
    case staged
    case committed
    case branch
}

/// A read of the chat session's repository that the pane asks for:
/// `git.diff` with `{cwd, scope, include_patch}`, `git.status` with
/// `{cwd}`, or `file.search` with `{cwd or path, query, limit?}`. The App
/// runs it as the session host's resource operation (`git.diff`,
/// `git.status`, `git.files.search`) with `cwd` as its `path`; it reads the
/// repository and changes nothing.
public nonisolated enum AgentPaneGitRequest: Equatable, Sendable {
    case diff(cwd: String, scope: AgentPaneGitScope, includePatch: Bool)
    case status(cwd: String)
    /// Files under `cwd` whose path matches `query`, best first.
    case filesSearch(cwd: String, query: String, limit: Int)
    /// One turn's changes: checkpoint `from` against `to`, or the working tree.
    case checkpointDiff(cwd: String, from: String, to: String?, includePatch: Bool)

    /// The longest query the session host takes, in characters.
    public static let maximumQueryLength = 256
    /// The session host's default and largest result counts.
    public static let defaultSearchLimit = 50
    public static let maximumSearchLimit = 200

    /// The session host's operation.
    public var operation: String {
        switch self {
        case .diff: "git.diff"
        case .status: "git.status"
        case .filesSearch: "git.files.search"
        case .checkpointDiff: "git.checkpoint.diff"
        }
    }

    /// The session's folder. Absolute: the session host would resolve a
    /// relative path against its own directory, not the chat's.
    public var cwd: String {
        switch self {
        case .diff(let cwd, _, _), .status(let cwd), .filesSearch(let cwd, _, _), .checkpointDiff(let cwd, _, _, _): cwd
        }
    }

    /// A checkpoint id as the session host mints them: 1 to 128 visible ASCII characters.
    static func isCheckpointId(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    /// Nil unless `method` is one of the four and `params` name an absolute
    /// folder (and, for a diff, one of the five scopes; for a search, a
    /// query of at most ``maximumQueryLength`` characters and a limit from 1
    /// to ``maximumSearchLimit``). A search names its folder as `cwd` or
    /// `path`.
    init?(method: String, params: [String: Any]?) {
        let folder = params?["cwd"] ?? (method == "file.search" ? params?["path"] : nil)
        guard let cwd = folder as? String, cwd.hasPrefix("/"), !cwd.contains("\u{0}") else { return nil }
        switch method {
        case "git.checkpoint.diff":
            guard let from = params?["from"] as? String, Self.isCheckpointId(from) else { return nil }
            let to = params?["to"] as? String
            if let to, !Self.isCheckpointId(to) { return nil }
            self = .checkpointDiff(cwd: cwd, from: from, to: to, includePatch: params?["include_patch"] as? Bool ?? false)
        case "file.search":
            guard let query = params?["query"] as? String, query.count <= Self.maximumQueryLength,
                  !query.contains("\u{0}") else { return nil }
            let limit: Int
            switch params?["limit"] {
            case nil, is NSNull: limit = Self.defaultSearchLimit
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                guard let exact = Int(exactly: number.doubleValue),
                      (1...Self.maximumSearchLimit).contains(exact) else { return nil }
                limit = exact
            default: return nil
            }
            self = .filesSearch(cwd: cwd, query: query, limit: limit)
        case "git.diff":
            guard let raw = params?["scope"] as? String, let scope = AgentPaneGitScope(rawValue: raw) else { return nil }
            self = .diff(cwd: cwd, scope: scope, includePatch: params?["include_patch"] as? Bool ?? false)
        case "git.status":
            self = .status(cwd: cwd)
        default:
            return nil
        }
    }
}

/// Why a git read failed, as the page gets it in `{ok: false, error}`.
/// With origin ``Origin/sessionHost`` the session host answered with a
/// resource error, and `code`, `details` and `retryable` are that error
/// verbatim. With ``Origin/native`` the request got no answer, and `code` is
/// one of the native codes below. The page always shows the localized
/// `agentPane.error.git` text.
public nonisolated struct AgentPaneGitFailure: Error, Equatable, Sendable {
    public nonisolated enum Origin: String, Equatable, Sendable {
        case sessionHost = "session_host"
        case native
    }

    /// The session host's code (`operation.failed`, `resource.not_found`,
    /// `selector.*`, …) or a native one.
    public let code: String
    /// The session host's `details` as JSON text (any JSON value), nil when
    /// it sent none.
    public let details: Data?
    public let retryable: Bool?
    public let origin: Origin

    public init(code: String, details: Data?, retryable: Bool?, origin: Origin) {
        self.code = code
        self.details = details
        self.retryable = retryable
        self.origin = origin
    }

    private init(native code: String) {
        self.init(code: code, details: nil, retryable: nil, origin: .native)
    }

    /// Definitely not sent: no connection to the session host.
    public static let notConnected = AgentPaneGitFailure(native: "native.not_connected")
    /// May have been sent: no reply in time, or the connection closed while
    /// the request was pending.
    public static let timedOut = AgentPaneGitFailure(native: "native.timed_out")
    /// The page bridge refused the request's params; never sent.
    public static let invalidRequest = AgentPaneGitFailure(native: "native.invalid_request")
    /// Anything else, such as a result that is not JSON.
    public static let failed = AgentPaneGitFailure(native: "native.failed")
}
