import Foundation

/// The Changes view's Commit (cx-tcwj, Codex desktop's commit box): `git.commit` with
/// `{cwd, message}`. The App commits what is staged in `cwd`'s repository with `message`, read by
/// `git commit -F -` from its input so no part of it is an option, and with the user's own git
/// settings and hooks. It needs a real click or key in the pane and `cwd` inside the pane's folders.
public nonisolated struct AgentPaneGitCommit: Equatable, Sendable {
    /// The chat's folder, absolute.
    public let cwd: String
    /// The message the user edited, as the commit keeps it.
    public let message: String

    /// The longest message one request carries, in UTF-8 bytes.
    public static let maximumMessageBytes = 64 * 1024
    /// How long git (and the user's commit hooks) may take before the request fails.
    static let timeout: Duration = .seconds(60)

    /// Nil unless `cwd` is absolute and `message` is a string with some text, at most
    /// ``maximumMessageBytes``, without NUL.
    public init?(params: [String: Any]?) {
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"),
              let message = params?["message"] as? String, !message.contains("\0"),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.utf8.count <= Self.maximumMessageBytes else { return nil }
        self.cwd = cwd
        self.message = message
    }

    /// Runs the request when `cwd` is inside one of `roots`. Nil on success, else git's message or
    /// why it did not run.
    static func run(_ request: AgentPaneGitCommit, roots: [String]) async -> String? {
        guard AgentPaneGitProcess.isInside(request.cwd, roots: roots) else { return AgentPaneGitStage.outsideMessage }
        return await AgentPaneGitProcess.run(["-C", request.cwd, "commit", "-F", "-"], input: Data(request.message.utf8),
                                             timeout: timeout)
    }
}

extension AgentPaneGitCommit {
    /// `git.commit` arrived without a real click or key press in the pane.
    nonisolated static var needsGestureMessage: String {
        String(localized: "agentPane.error.gitCommitGesture", defaultValue: "Committing needs a click or key press in the pane.",
               bundle: .module)
    }

    /// `git.commit` whose params break its contract.
    nonisolated static var invalidMessage: String {
        String(localized: "agentPane.error.gitCommitInvalid", defaultValue: "The app refused the commit request.", bundle: .module)
    }

    /// `git.commit` (nil: params that break the contract): spends `model`'s GRANT credit, then
    /// commits in the chat's folder.
    @MainActor static func reply(to request: AgentPaneGitCommit?, in model: AgentPaneModel) async -> [String: Any] {
        guard let request else { return AgentPaneReply.failure(code: "native.invalid_request", message: invalidMessage) }
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
