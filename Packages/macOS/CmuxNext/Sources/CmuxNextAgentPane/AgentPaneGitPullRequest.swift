import Foundation

/// The Changes view's Create PR (cx-tcwj, Codex desktop's): `git.pullRequest` with `{cwd}`. The
/// App pushes the chat's checked-out branch (the first time setting its upstream on `origin`, or
/// the only remote) and opens its pull request with the GitHub CLI: the open one when the branch
/// has one, else `gh pr create --fill` from its commits. It answers `{url, number}`. It needs a
/// real click or key in the pane, a chat on this Mac and `cwd` inside the pane's folders; neither
/// git nor gh ever prompts, and each step has a deadline.
public nonisolated struct AgentPaneGitPullRequest: Equatable, Sendable {
    /// The chat's folder, absolute.
    public let cwd: String

    public init?(params: [String: Any]?) {
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") else { return nil }
        self.cwd = cwd
    }

    /// The pull request the run opened, or why it did not.
    enum Outcome: Equatable {
        case opened(url: String, number: Int?)
        case refused(String)
    }

    static let localTimeout: Duration = .seconds(20)
    static let networkTimeout: Duration = .seconds(120)

    /// Pushes and opens the pull request where ``AgentPaneGitProcess/place(_:roots:home:)``
    /// allows, with `gh` at that path (nil: not installed).
    @concurrent static func run(_ request: AgentPaneGitPullRequest, roots: [String], home: String = NSHomeDirectory(),
                                gh: String?) async -> Outcome {
        let folder: String
        switch await AgentPaneGitProcess.place(request.cwd, roots: roots, home: home) {
        case .refused(let message): return .refused(message)
        case .folder(let resolved): folder = resolved
        }
        guard let gh else { return .refused(noGitHubCLIMessage) }
        let git = { (arguments: [String]) in await AgentPaneGitProcess.output(["-C", folder] + arguments, timeout: localTimeout) }
        guard await git(["symbolic-ref", "--quiet", "--short", "HEAD"]).status == 0 else { return .refused(detachedMessage) }
        var push = ["-C", folder, "push"]
        if await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]).status != 0 {
            let remotes = await git(["remote"]).text.split(separator: "\n").map(String.init)
            guard let remote = remotes.contains("origin") ? "origin" : remotes.count == 1 ? remotes[0] : nil else {
                return .refused(noRemoteMessage)
            }
            push += ["--set-upstream", remote, "HEAD"]
        }
        if let message = await AgentPaneGitProcess.run(push, timeout: networkTimeout, network: true) { return .refused(message) }
        let cli = { (arguments: [String]) in
            await AgentPaneGitProcess.output(arguments, executable: gh, directory: folder, timeout: networkTimeout, network: true)
        }
        let open = await cli(["pr", "view", "--json", "url,number"])
        if open.status == 0, let opened = opened(fromView: open.text) { return opened }
        let created = await cli(["pr", "create", "--fill"])
        guard created.status == 0, let url = created.text.split(separator: "\n").map(String.init).last(where: isPullRequestURL) else {
            return .refused(created.message)
        }
        return .opened(url: url, number: Int(url.split(separator: "/").last ?? ""))
    }

    /// `gh pr view --json url,number`'s answer.
    static func opened(fromView text: String) -> Outcome? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let url = object["url"] as? String, isPullRequestURL(url) else { return nil }
        return .opened(url: url, number: object["number"] as? Int)
    }

    /// An https address, the only kind the page links.
    static func isPullRequestURL(_ text: String) -> Bool {
        text.hasPrefix("https://") && !text.contains(where: \.isWhitespace)
    }

    /// `gh` in the App's PATH or the user's usual install folders.
    static func gitHubCLI(_ app: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        AgentPaneGitProcess.toolFolders(app).map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

extension AgentPaneGitPullRequest {
    /// No `gh` in the user's usual install folders.
    nonisolated static var noGitHubCLIMessage: String {
        String(localized: "agentPane.error.gitNoGitHubCLI", defaultValue: "Install the GitHub CLI (gh) to open a pull request.",
               bundle: .module)
    }

    /// The repository has no branch checked out.
    nonisolated static var detachedMessage: String {
        String(localized: "agentPane.error.gitDetached", defaultValue: "Check out a branch to open a pull request.", bundle: .module)
    }

    /// The branch has no upstream and the repository no remote to push it to.
    nonisolated static var noRemoteMessage: String {
        String(localized: "agentPane.error.gitNoRemote", defaultValue: "This repository has no remote to push to.", bundle: .module)
    }

    /// `git.pullRequest` arrived without a real click or key press in the pane.
    nonisolated static var needsGestureMessage: String {
        String(localized: "agentPane.error.gitPullRequestGesture",
               defaultValue: "Opening a pull request needs a click or key press in the pane.", bundle: .module)
    }

    /// `git.pullRequest` (nil: params that break the contract): spends `model`'s GRANT credit, then
    /// pushes and opens the pull request, for a chat on this Mac only.
    @MainActor static func reply(to request: AgentPaneGitPullRequest?, in model: AgentPaneModel) async -> [String: Any] {
        guard let request else { return AgentPaneReply.failure(code: "native.invalid_request", message: invalidMessage) }
        guard model.gitWritesHere?() == true else {
            return AgentPaneReply.failure(code: "git.remote", message: AgentPaneGitProcess.remoteMessage)
        }
        guard model.transport.gestures.consume() else {
            return AgentPaneReply.failure(code: AgentPaneTransportError.gestureRequired.rawValue,
                                          message: needsGestureMessage, details: nil, retryable: nil, origin: "native")
        }
        switch await run(request, roots: model.roots() + model.transport.addedRoots, gh: gitHubCLI()) {
        case .opened(let url, let number): return AgentPaneReply.success(["url": url, "number": number.map { $0 as Any } ?? NSNull()])
        case .refused(let message): return AgentPaneReply.failure(code: "git.failed", message: message)
        }
    }

    /// `git.pullRequest` whose params break its contract.
    nonisolated static var invalidMessage: String {
        String(localized: "agentPane.error.gitPullRequestInvalid", defaultValue: "The app refused to open that pull request.",
               bundle: .module)
    }
}
