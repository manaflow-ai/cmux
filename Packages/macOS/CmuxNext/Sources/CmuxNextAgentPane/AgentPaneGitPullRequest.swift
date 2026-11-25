import Foundation

/// The Changes view's Create PR (cx-tcwj, Codex desktop's): `git.pullRequest` with `{cwd}`. The
/// App opens the pull request of the chat's checked-out branch with the GitHub CLI: the open one
/// when the branch has one, else `gh pr create --web` (only when gh says the branch has none: a
/// failed lookup opens nothing). It answers the compare-form URL that gh opened. Before asking
/// `gh`, it asks the session host's Rust `git.push` mutation to push the branch and set its
/// upstream when needed; that mutation never force-pushes and reports actionable remote errors.
/// It needs a real click or key in the pane, a chat on this
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
    public enum Outcome: Equatable, Sendable {
        case opened(url: String, number: Int?)
        /// `gh pr create --web` opened the compare form itself; no second browser open is needed.
        case formOpened(url: String)
        case threads(url: String?, number: Int?, [AgentPaneGitReviewThread])
        case merged(url: String, number: Int, queued: Bool)
        case refused(String)
    }

    static let localTimeout: Duration = .seconds(20)
    static let networkTimeout: Duration = .seconds(60)

    /// The shared diff page uses the same Create PR flow with its grant-bound push wire.
    public static func open(in repository: String,
                            push: @escaping @Sendable (String, String?) async throws -> Void) async -> Outcome {
        guard let request = Self(params: ["cwd": repository]) else { return .refused(pushUnavailableMessage) }
        return await run(request, roots: [repository], gh: gitHubCLI(), push: push)
    }

    /// Opens the pull request where ``AgentPaneGitProcess/place(_:roots:home:)`` allows, with `gh`
    /// at that path (nil: not installed).
    @concurrent static func run(_ request: AgentPaneGitPullRequest, roots: [String], home: String = NSHomeDirectory(),
                                gh: String?, push: (@Sendable (String, String?) async throws -> Void)? = nil) async -> Outcome {
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
        let branch = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = await git(["rev-parse", "HEAD"])
        guard commit.status == 0 else { return .refused(pushUnavailableMessage) }
        guard let push else { return .refused(pushUnavailableMessage) }
        do {
            try await push(folder, commit.text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as AgentPaneGitFailure {
            return .refused(pushMessage(error))
        } catch {
            return .refused(pushUnavailableMessage)
        }
        let cli = { (arguments: [String]) in
            await AgentPaneGitProcess.output(arguments, executable: gh, directory: folder, timeout: networkTimeout, network: true)
        }
        let open = await cli(["pr", "view", "--json", "url,number,state"])
        if open.status == 0, let opened = opened(fromView: open.text) { return opened }
        // Create only when gh found no pull request, or only a merged or closed one.
        guard open.status == 0 || open.text.contains("no pull requests found") else { return .refused(message(open)) }
        let target = await recordedBase(of: branch, git: git)
        let repo = await cli(["repo", "view", "--json", "url,defaultBranchRef"])
        guard repo.status == 0, let formURL = await formURL(branch: branch, base: target, repo: repo.text, git: git) else {
            return .refused(message(repo))
        }
        // Do not pass --head: after the Rust push establishes the upstream, gh resolves the
        // tracking repository (including a fork) itself. Passing only a branch silently selects
        // the base repository and loses that fork selection.
        let created = await cli(["pr", "create", "--web"] + (target.map { ["--base", $0] } ?? []))
        guard created.status == 0 else { return .refused(message(created)) }
        return .formOpened(url: formURL)
    }

    /// The compare URL that `gh pr create --web` opens without printing. `repo` comes from
    /// `gh repo view`; the configured push remote supplies the fork owner, and a tracked branch
    /// name is reused only when it is on that same remote. This is only a link for the result
    /// wire: gh has already opened it.
    static func formURL(branch: String, base: String?, repo: String,
                        git: (_ arguments: [String]) async -> AgentPaneGitProcess.Outcome) async -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(repo.utf8)) as? [String: Any],
              let baseURL = object["url"] as? String,
              isPullRequestURL(baseURL),
              let defaultBase = (object["defaultBranchRef"] as? [String: Any])?["name"] as? String else { return nil }
        let remote = await configuredPushRemote(branch: branch, git: git)
        guard !remote.isEmpty else { return nil }
        let remoteURL = await git(["remote", "get-url", remote])
        guard remoteURL.status == 0 else { return nil }
        let trackingRemote = await configValue("branch.\(branch).remote", git: git)
        let trackingMerge = await configValue("branch.\(branch).merge", git: git)
            .flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
        let destination = trackingRemote == remote ? (trackingMerge ?? branch) : branch
        let head = AgentPaneGitHubRepository.parse(remoteURL.text).map { "\($0):\(destination)" } ?? destination
        let base = base ?? defaultBase
        guard !base.isEmpty, !base.contains(where: \.isWhitespace),
              !head.contains(where: \.isWhitespace),
              let encodedBase = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedHead = head.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/compare/\(encodedBase)...\(encodedHead)?expand=1"
    }

    /// The remote Rust's `git.push` selects, in the same order, for the compare URL.
    static func configuredPushRemote(branch: String,
                                    git: (_ arguments: [String]) async -> AgentPaneGitProcess.Outcome) async -> String {
        if let remote = await configValue("branch.\(branch).pushRemote", git: git) { return remote }
        if let remote = await configValue("remote.pushDefault", git: git) { return remote }
        return await configValue("branch.\(branch).remote", git: git) ?? ""
    }

    static func configValue(_ key: String,
                            git: (_ arguments: [String]) async -> AgentPaneGitProcess.Outcome) async -> String? {
        let outcome = await git(["config", "--get", key])
        guard outcome.status == 0 else { return nil }
        let value = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
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

    /// The branch has no upstream, or commits its upstream lacks. Kept for the
    /// Changes page's existing wording; Create PR now invokes the Rust push.
    nonisolated static var pushFirstMessage: String {
        String(localized: "agentPane.error.gitPushFirst",
               defaultValue: "Push this branch first; the pull request opens from what's on the remote.", bundle: .module)
    }

    /// The Create PR caller did not provide the session-host push wire.
    nonisolated static var pushUnavailableMessage: String {
        String(localized: "agentPane.error.gitPushUnavailable",
               defaultValue: "The branch could not be pushed; reconnect the chat and try again.", bundle: .module)
    }

    /// The Rust push mutation carries its machine reason and an actionable
    /// message in `details.extra.message`. Keep that message as the inline
    /// Create PR error instead of hiding it behind the generic git text.
    nonisolated static func pushMessage(_ failure: AgentPaneGitFailure) -> String {
        guard let data = failure.details,
              let details = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extra = details["extra"] as? [String: Any],
              let message = extra["message"] as? String, !message.isEmpty else {
            return pushUnavailableMessage
        }
        return message
    }

    nonisolated static var sessionRepositoryMessage: String {
        "The pull request folder is not this chat's repository. Refresh the chat and try again."
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
        guard gh != nil else {
            return AgentPaneReply.failure(code: "git.failed", message: noGitHubCLIMessage)
        }
        let push: (@Sendable (String, String?) async throws -> Void)?
        var runRoots = model.fileOpenRoots()
        if request.readsThreads || request.merges != nil {
            push = nil
        } else {
            let sessionFolder: AgentPaneSessionFolder?
            do {
                sessionFolder = try await model.host.sessionFolder(sessionId: model.sessionId ?? "")
            } catch {
                return AgentPaneReply.failure(code: "git.failed", message: pushUnavailableMessage)
            }
            guard let sessionFolder, sessionFolder.isLocal, sessionFolder.cwd.hasPrefix("/") else {
                return AgentPaneReply.failure(code: "git.failed", message: pushUnavailableMessage)
            }
            guard case .folder(let requestedFolder) = await AgentPaneGitProcess.place(request.cwd,
                                                                                        roots: [sessionFolder.cwd],
                                                                                        home: NSHomeDirectory()) else {
                return AgentPaneReply.failure(code: "git.failed", message: sessionRepositoryMessage)
            }
            let requestedTop = await AgentPaneGitProcess.output(["-C", requestedFolder, "rev-parse", "--show-toplevel"], timeout: localTimeout)
            let sessionTop = await AgentPaneGitProcess.output(["-C", sessionFolder.cwd, "rev-parse", "--show-toplevel"], timeout: localTimeout)
            guard requestedTop.status == 0, sessionTop.status == 0,
                  let requestedRoot = AcpmuxPathPolicy.canonical(requestedTop.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let sessionRoot = AcpmuxPathPolicy.canonical(sessionTop.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  requestedRoot == sessionRoot else {
                return AgentPaneReply.failure(code: "git.failed", message: sessionRepositoryMessage)
            }
            guard let onGitWrite = model.onGitWrite, let sessionId = model.sessionId else {
                return AgentPaneReply.failure(code: "git.failed", message: pushUnavailableMessage)
            }
            let pushKey = UUID().uuidString
            let pushFolder = sessionFolder.cwd
            push = { @MainActor _, expectedHead in
                // Leave the upstream decision to Rust: a fresh branch gets an upstream for the
                // selected push remote. Rust refuses an ambiguous upstream branch name
                // instead of silently updating the branch it was created from.
                _ = try await onGitWrite(.push(sessionId: sessionId, expectedHead: expectedHead, setUpstream: false, key: pushKey), pushFolder)
            }
            runRoots = [sessionFolder.cwd]
        }
        switch await run(request, roots: runRoots, gh: gh, push: push) {
        case .opened(let url, let number): return AgentPaneReply.success(["url": url, "number": number.map { $0 as Any } ?? NSNull()])
        case .formOpened(let url): return AgentPaneReply.success(["url": url, "number": NSNull()])
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
