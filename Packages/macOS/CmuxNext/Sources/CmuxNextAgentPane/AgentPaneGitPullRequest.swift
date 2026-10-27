import CmuxNextCompat
import Foundation

/// The Changes view's Create PR (cx-tcwj, Codex desktop's): `git.pullRequest` with `{cwd}`. The
/// App opens the pull request of the chat's checked-out branch with the GitHub CLI: the open one
/// when the branch has one, else `gh pr create --fill` from its commits (only when gh says the
/// branch has none: a failed lookup creates nothing). It answers `{url, number}`. It never pushes
/// (the session host's Push does, cx-ncc.1), so a branch that is not exactly its upstream (none,
/// ahead or behind) is refused, and gh never has anything to push. It needs a real click or key in the pane, a chat on this
/// Mac and `cwd` inside the pane's folders; gh never prompts, and each step has a deadline. A
/// worktree chat's branch targets the branch it was made from (cx-lyqio.6), not the default.
public nonisolated struct AgentPaneGitPullRequest: Equatable, Sendable {
    /// The chat's folder, absolute.
    public let cwd: String
    /// `{action: "threads"}`: read the pull request's review threads instead (cx-ncc.77.2,
    /// AgentPaneGitReviewThreads.swift); a read needs no click.
    public let readsThreads: Bool
    /// `{action: "merge", number, url}`: merge that pull request, the one the page showed
    /// (cx-ncc.77.4, AgentPaneGitMerge.swift).
    public let merges: Int?
    public let mergeURL: String?

    public init?(params: [String: Any]?) {
        guard let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0") else { return nil }
        self.cwd = cwd
        readsThreads = params?["action"] as? String == "threads"
        if params?["action"] as? String == "merge" {
            guard let number = params?["number"] as? Int, number > 0, let url = params?["url"] as? String,
                  Self.isPullRequestURL(url) else { return nil }
            merges = number
            mergeURL = url
        } else {
            merges = nil
            mergeURL = nil
        }
    }

    /// The pull request the run opened (or the threads it read), or why it did not.
    enum Outcome: Equatable {
        case opened(url: String, number: Int?)
        case threads(url: String?, number: Int?, [AgentPaneGitReviewThread])
        case merged(url: String, number: Int, queued: Bool)
        case refused(String)
    }

    static let localTimeout: Duration = .seconds(20)
    static let networkTimeout: Duration = .seconds(60)

    /// Opens the pull request where ``AgentPaneGitProcess/place(_:roots:home:)`` allows, with `gh`
    /// at that path (nil: not installed).
    @concurrent static func run(_ request: AgentPaneGitPullRequest, roots: [String], home: String = NSHomeDirectory(),
                                gh: String?) async -> Outcome {
        let folder: String
        switch await AgentPaneGitProcess.place(request.cwd, roots: roots, home: home) {
        case .refused(let message): return .refused(message)
        case .folder(let resolved): folder = resolved
        }
        guard let gh else { return .refused(noGitHubCLIMessage) }
        if request.readsThreads { return await threads(in: folder, gh: gh) }
        if let number = request.merges, let url = request.mergeURL { return await merge(number, url: url, in: folder, gh: gh) }
        let git = { (arguments: [String]) in await AgentPaneGitProcess.output(["-C", folder] + arguments, timeout: localTimeout) }
        let head = await git(["symbolic-ref", "--quiet", "--short", "HEAD"])
        guard head.status == 0 else { return .refused(detachedMessage) }
        let counts = await git(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"])
        let behindAhead = counts.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.status == 0, behindAhead.count == 2, behindAhead[1] == 0 else { return .refused(pushFirstMessage) }
        guard behindAhead[0] == 0 else { return .refused(pullFirstMessage) }
        let cli = { (arguments: [String]) in
            await AgentPaneGitProcess.output(arguments, executable: gh, directory: folder, timeout: networkTimeout, network: true)
        }
        let open = await cli(["pr", "view", "--json", "url,number,state"])
        if open.status == 0, let opened = opened(fromView: open.text) { return opened }
        // Create only when gh found no pull request, or only a merged or closed one.
        guard open.status == 0 || open.text.contains("no pull requests found") else { return .refused(message(open)) }
        let target = await recordedBase(of: head.text.trimmingCharacters(in: .whitespacesAndNewlines), git: git)
        let created = await cli(["pr", "create", "--fill"] + (target.map { ["--base", $0] } ?? []))
        guard created.status == 0, let url = created.text.split(separator: "\n").map(String.init).last(where: isPullRequestURL) else {
            return .refused(message(created))
        }
        return .opened(url: url, number: Int(url.split(separator: "/").last ?? ""))
    }

    /// The remote name of the branch `branch` was made from (`branch.<b>.cmuxBase`, recorded by the
    /// session host's `git.worktree.create`): a local branch by its upstream's name, a
    /// remote-tracking branch without its remote. Nil (gh's default, as before) for no record, a
    /// commit, a local branch with no upstream, or the remote's HEAD.
    static func recordedBase(of branch: String,
                             git: (_ arguments: [String]) async -> AgentPaneGitProcess.Outcome) async -> String? {
        let recorded = await git(["config", "--get", "branch.\(branch).cmuxBase"])
        let base = recorded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recorded.status == 0, !base.isEmpty, !base.hasPrefix("-") else { return nil }
        if await git(["show-ref", "--verify", "--quiet", "refs/heads/\(base)"]).status == 0 {
            let merge = await git(["config", "--get", "branch.\(base).merge"])
            let upstream = merge.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard merge.status == 0, upstream.hasPrefix("refs/heads/") else { return nil }
            return String(upstream.dropFirst("refs/heads/".count))
        }
        guard await git(["show-ref", "--verify", "--quiet", "refs/remotes/\(base)"]).status == 0,
              let slash = base.firstIndex(of: "/") else { return nil }
        let name = String(base[base.index(after: slash)...])
        return name.isEmpty || name == "HEAD" ? nil : name
    }

    /// `gh pr view --json url,number,state`'s answer when that pull request is open.
    static func opened(fromView text: String) -> Outcome? {
        guard let object = try? JSONSerialization.blockingJSONObject(with: Data(text.utf8)) as? [String: Any],
              (object["state"] as? String)?.uppercased() == "OPEN",
              let url = object["url"] as? String, isPullRequestURL(url) else { return nil }
        return .opened(url: url, number: object["number"] as? Int)
    }

    /// Why a gh step failed: its last line that is not a warning or an address (gh names the
    /// reason last, after warnings such as uncommitted changes).
    static func message(_ outcome: AgentPaneGitProcess.Outcome) -> String {
        let lines = outcome.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last { !$0.isEmpty && !$0.hasPrefix("Warning:") && !isPullRequestURL($0) } ?? outcome.message
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

    /// The branch has no upstream, or commits its upstream lacks.
    nonisolated static var pushFirstMessage: String {
        String(localized: "agentPane.error.gitPushFirst",
               defaultValue: "Push this branch first; the pull request opens from what's on the remote.", bundle: .module)
    }

    /// The branch is behind its upstream (pushed from elsewhere).
    nonisolated static var pullFirstMessage: String {
        String(localized: "agentPane.error.gitPullFirst",
               defaultValue: "This branch is behind its remote. Pull first, then open the pull request.", bundle: .module)
    }

    /// `git.pullRequest` arrived without a real click or key press in the pane.
    nonisolated static var needsGestureMessage: String {
        String(localized: "agentPane.error.gitPullRequestGesture",
               defaultValue: "Opening a pull request needs a click or key press in the pane.", bundle: .module)
    }

    /// `git.pullRequest` (nil: params that break the contract), for a chat on this Mac only: spends
    /// `model`'s GRANT credit, then opens the pull request; a threads read needs no credit.
    @MainActor static func reply(to request: AgentPaneGitPullRequest?, in model: AgentPaneModel,
                                 gh: String? = gitHubCLI()) async -> [String: Any] {
        guard let request else { return AgentPaneReply.failure(code: "native.invalid_request", message: invalidMessage) }
        guard model.gitWritesHere?() == true else {
            return AgentPaneReply.failure(code: "git.remote", message: AgentPaneGitProcess.remoteMessage)
        }
        guard request.readsThreads || model.transport.gestures.consume() else {
            return AgentPaneReply.failure(code: AgentPaneTransportError.gestureRequired.rawValue,
                                          message: needsGestureMessage, details: nil, retryable: nil, origin: "native")
        }
        switch await run(request, roots: model.fileOpenRoots(), gh: gh) {
        case .opened(let url, let number): return AgentPaneReply.success(["url": url, "number": number.map { $0 as Any } ?? NSNull()])
        case .threads(let url, let number, let threads):
            return AgentPaneReply.success(["url": url.map { $0 as Any } ?? NSNull(), "number": number.map { $0 as Any } ?? NSNull(),
                                           "threads": threads.map(\.json)])
        case .merged(let url, let number, let queued):
            return AgentPaneReply.success(["url": url, "number": number, "merged": !queued, "queued": queued])
        case .refused(let message): return AgentPaneReply.failure(code: "git.failed", message: message)
        }
    }

    /// `git.pullRequest` whose params break its contract.
    nonisolated static var invalidMessage: String {
        String(localized: "agentPane.error.gitPullRequestInvalid", defaultValue: "The app refused to open that pull request.",
               bundle: .module)
    }
}
