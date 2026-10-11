import Foundation

/// The Changes view's Stage and Unstage (cx-tcwj, Codex desktop's staging): `git.stage` and
/// `git.unstage` with `{cwd, paths}`. The App runs `git add` or `git restore --staged` in `cwd` on
/// those files, as the user's own git does. It needs a real click or key in the pane, `cwd` inside
/// the pane's folders, and paths that never leave the repository.
public nonisolated struct AgentPaneGitStage: Equatable, Sendable {
    public enum Action: String, Sendable {
        case stage, unstage
    }

    public let action: Action
    /// The chat's folder, absolute.
    public let cwd: String
    /// Files relative to the top of `cwd`'s repository, as `git.diff` names them.
    public let paths: [String]

    /// The most files one request names.
    public static let maximumPaths = 1000
    /// How long git may take before the request fails.
    static let timeout: Duration = .seconds(20)

    /// Nil unless `method` is `git.stage` or `git.unstage`, `cwd` is absolute, and `paths` holds 1
    /// to ``maximumPaths`` relative paths without NUL or `.`, `..` or empty segments.
    public init?(method: String, params: [String: Any]?) {
        let action: Action
        switch method {
        case "git.stage": action = .stage
        case "git.unstage": action = .unstage
        default: return nil
        }
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"),
              let paths = params?["paths"] as? [String], (1...Self.maximumPaths).contains(paths.count),
              paths.allSatisfy(Self.isInside) else { return nil }
        self.action = action
        self.cwd = cwd
        self.paths = paths
    }

    /// A path that names something under the repository's top and never the top itself: relative,
    /// no NUL, no `.`, `..` or empty segment (so not `.`, `a/.` or `a//b`).
    static func isInside(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !["", ".", ".."].contains($0) }
    }

    /// git's arguments in `folder`, the chat's folder resolved. Literal pathspecs from the
    /// repository's top after `--`: a file named like an option or a glob is that file, and a chat
    /// in a subfolder names files as `git.diff` does.
    func arguments(in folder: String) -> [String] {
        let pathspecs = paths.map { ":(top,literal)" + $0 }
        switch action {
        case .stage: return ["-C", folder, "add", "--"] + pathspecs
        case .unstage: return ["-C", folder, "restore", "--staged", "--"] + pathspecs
        }
    }

    /// Runs the request where ``AgentPaneGitProcess/place(_:roots:home:)`` allows. Nil on success,
    /// else git's message or why it did not run.
    @concurrent static func run(_ request: AgentPaneGitStage, roots: [String], home: String = NSHomeDirectory()) async -> String? {
        switch await AgentPaneGitProcess.place(request.cwd, roots: roots, home: home) {
        case .refused(let message): return message
        case .folder(let folder): return await AgentPaneGitProcess.run(request.arguments(in: folder), timeout: timeout)
        }
    }
}

extension AgentPaneGitStage {
    /// `git.stage` or `git.unstage` arrived without a real click or key press in the pane.
    nonisolated static var needsGestureMessage: String {
        String(localized: "agentPane.error.gitStageGesture", defaultValue: "Staging needs a click or key press in the pane.",
               bundle: .module)
    }

    /// `git.stage` or `git.unstage` whose params break its contract.
    nonisolated static var invalidMessage: String {
        String(localized: "agentPane.error.gitStageInvalid", defaultValue: "The app refused the staging request.", bundle: .module)
    }

    /// The repository is outside the pane's folders.
    nonisolated static var outsideMessage: String {
        String(localized: "agentPane.error.gitStageOutside", defaultValue: "That folder is outside this chat's folders.",
               bundle: .module)
    }

    /// `git.stage` / `git.unstage` (nil: params that break the contract): spends `model`'s GRANT
    /// credit, then runs git in the chat's folder, for a chat on this Mac only.
    @MainActor static func reply(to request: AgentPaneGitStage?, in model: AgentPaneModel) async -> [String: Any] {
        guard let request else { return AgentPaneReply.failure(code: "native.invalid_request", message: invalidMessage) }
        guard model.gitWritesHere?() == true else {
            return AgentPaneReply.failure(code: "git.remote", message: AgentPaneGitProcess.remoteMessage)
        }
        guard model.transport.gestures.consume() else {
            return AgentPaneReply.failure(code: AgentPaneTransportError.gestureRequired.rawValue,
                                          message: needsGestureMessage, details: nil, retryable: nil, origin: "native")
        }
        if let message = await run(request, roots: model.roots() + model.transport.addedRoots) {
            return AgentPaneReply.failure(code: "git.failed", message: message)
        }
        return AgentPaneReply.success()
    }
}
