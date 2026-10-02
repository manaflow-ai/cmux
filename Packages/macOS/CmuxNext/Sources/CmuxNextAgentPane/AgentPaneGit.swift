public import Foundation

/// A scope of `git.diff` on the session host (cmux-tui `GitDiffScope`).
public nonisolated enum AgentPaneGitScope: String, CaseIterable, Equatable, Sendable {
    case uncommitted
    case unstaged
    case staged
    case committed
    case branch
}

/// A read of the chat session's repository that the changes view asks for:
/// `git.diff` with `{cwd, scope, include_patch}` or `git.status` with
/// `{cwd}`. The App runs it as the session host's resource operation of the
/// same name with `cwd` as its `path`; it reads the repository and changes
/// nothing.
public nonisolated enum AgentPaneGitRequest: Equatable, Sendable {
    case diff(cwd: String, scope: AgentPaneGitScope, includePatch: Bool)
    case status(cwd: String)

    /// The session host's operation.
    public var operation: String {
        switch self {
        case .diff: "git.diff"
        case .status: "git.status"
        }
    }

    /// The session's folder. Absolute: the session host would resolve a
    /// relative path against its own directory, not the chat's.
    public var cwd: String {
        switch self {
        case .diff(let cwd, _, _), .status(let cwd): cwd
        }
    }

    /// Nil unless `method` is one of the two and `params` name an absolute
    /// folder (and, for a diff, one of the five scopes).
    init?(method: String, params: [String: Any]?) {
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\u{0}") else { return nil }
        switch method {
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
