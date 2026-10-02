public import Foundation

/// A scope of `git.diff` on the session host (cmux-tui `GitDiffScope`).
public nonisolated enum AgentPaneGitScope: String, CaseIterable, Equatable, Sendable {
    case uncommitted
    case unstaged
    case staged
    case committed
    case branch
}

/// A git request of the agent pane's page, which the App runs on the session
/// host as the resource operation of the same name with `cwd` as its `path`:
/// the changes view's reads `git.diff` with `{cwd, scope, include_patch}` and
/// `git.status` with `{cwd}`, the checkpoint review's operations
/// (``AgentPaneCheckpointRequest``), and `git.capabilities` with `{}`, which
/// the App answers `{checkpoints}` itself from the session host's identify.
public nonisolated enum AgentPaneGitRequest: Equatable, Sendable {
    case diff(cwd: String, scope: AgentPaneGitScope, includePatch: Bool)
    case status(cwd: String)
    /// Whether the session host serves checkpoints (`git-checkpoints-v1`).
    case capabilities
    case checkpoint(AgentPaneCheckpointRequest)

    /// Every page method this type parses.
    public static let methods: Set<String> = AgentPaneCheckpointRequest.methods
        .union(["git.diff", "git.status", "git.capabilities"])

    /// The session host's operation (`git.capabilities` for the App's own).
    public var operation: String {
        switch self {
        case .diff: "git.diff"
        case .status: "git.status"
        case .capabilities: "git.capabilities"
        case .checkpoint(let checkpoint): checkpoint.operation
        }
    }

    /// The session's folder. Absolute: the session host would resolve a
    /// relative path against its own directory, not the chat's. Nil for
    /// `git.capabilities`, which names none.
    public var cwd: String? {
        switch self {
        case .diff(let cwd, _, _), .status(let cwd): cwd
        case .capabilities: nil
        case .checkpoint(let checkpoint): checkpoint.cwd
        }
    }

    /// The request envelope's `idempotency_key`, set only on a mutation.
    public var idempotencyKey: String? {
        guard case .checkpoint(let checkpoint) = self else { return nil }
        return checkpoint.idempotencyKey
    }

    /// Nil unless `method` is one of ``methods`` and `params` are what it
    /// takes: an absolute folder (and, for a diff, one of the five scopes);
    /// no params for `git.capabilities`; the checkpoint fields
    /// ``AgentPaneCheckpointRequest`` parses.
    init?(method: String, params: [String: Any]?) {
        switch method {
        case "git.capabilities":
            guard params?.isEmpty ?? true else { return nil }
            self = .capabilities
        case "git.diff":
            guard let cwd = Self.folder(params?["cwd"]),
                  let raw = params?["scope"] as? String, let scope = AgentPaneGitScope(rawValue: raw) else { return nil }
            self = .diff(cwd: cwd, scope: scope, includePatch: params?["include_patch"] as? Bool ?? false)
        case "git.status":
            guard let cwd = Self.folder(params?["cwd"]) else { return nil }
            self = .status(cwd: cwd)
        default:
            guard let checkpoint = AgentPaneCheckpointRequest(method: method, params: params) else { return nil }
            self = .checkpoint(checkpoint)
        }
    }

    /// `value` when it is an absolute path with no NUL.
    static func folder(_ value: Any?) -> String? {
        guard let cwd = value as? String, cwd.hasPrefix("/"), !cwd.contains("\u{0}") else { return nil }
        return cwd
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
