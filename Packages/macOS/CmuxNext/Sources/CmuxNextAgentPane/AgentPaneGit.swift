import Foundation

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
