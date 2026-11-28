public import CmuxNextActions
public import CmuxNextCloud
import CmuxNextCompat
public import Foundation

/// The new chat folder picker's GitHub section: `github.status {}`, `github.connect {}`,
/// `github.repos.list {query?}` and `github.repos.checkout {repo, candidates?}` (``AgentPaneGitHub`` answers
/// them). The section lists the person's repositories the cmux GitHub App reaches; a Cloud chat started in one
/// runs in the machine's clone (`github:owner/name`, ``AgentPaneGitHubFolder``), and a chat on this Mac in this
/// Mac's checkout of it, cloned first when there is none (``AgentPaneGitHubCheckout``).
public nonisolated enum AgentPaneGitHubRequest: Equatable, Sendable {
    case status
    /// `repo` (`owner/name`): a Cloud start's Connect GitHub card for the repository its machine could not clone (#55104).
    case connect(repo: String?)
    /// `github.connect {add_account: true}`: the picker's Add organization. GitHub's install page with its account
    /// chooser, even for a team already connected (a new connection beside the first; ``CloudGitHubPicker/connect(repo:addAccount:)``).
    case addAccount
    case repos(query: String?)
    /// `repo` (`owner/name`) as a folder on this Mac: one of `candidates` (the folders the page knows for it)
    /// or the default clone folder when one is a checkout of it, else a new clone there.
    /// The pane model answers it (``AgentPaneGitWriteReply/gitHubCheckout(repo:candidates:key:in:)``): it ends in the chat's
    /// worktree of that checkout, as New Worktree's `git.worktree.create` does, on the same click.
    case checkout(repo: String, candidates: [String], key: String)

    /// Clone a credential-free HTTPS URL on this Mac, without creating a worktree.
    case cloneURL(url: String, key: String)

    public static let methods: Set<String> = ["github.status", "github.connect", "github.repos.list", "github.repos.checkout", "repo.clone"]

    /// The page's params, checked; nil for anything else. `query` is the picker's search text, or null.
    init?(method: String, params: [String: Any]?) {
        switch method {
        case "github.status": self = .status
        case "github.connect":
            if params?["add_account"] as? Bool == true, params?["repo"] == nil || params?["repo"] is NSNull {
                self = .addAccount
                return
            }
            switch params?["repo"] {
            case nil, is NSNull: self = .connect(repo: nil)
            case let repo as String where CloudGitHubRepos.isFullName(repo): self = .connect(repo: repo)
            default: return nil
            }
        case "github.repos.list":
            let query = params?["query"]
            if query == nil || query is NSNull {
                self = .repos(query: nil)
            } else if let text = query as? String, text.utf8.count <= 1024, !text.contains("\0") {
                self = .repos(query: text)
            } else {
                return nil
            }
        case "repo.clone":
            guard let url = params?["url"] as? String, url.utf8.count <= 4096, !url.contains("\0"),
                  let key = params?["idempotency_key"] as? String, AgentPaneGitWrite.isKey(key) else { return nil }
            self = .cloneURL(url: url, key: key)
        case "github.repos.checkout":
            guard let repo = params?["repo"] as? String, CloudGitHubRepos.isFullName(repo),
                  let key = params?["idempotency_key"] as? String, AgentPaneGitWrite.isKey(key) else { return nil }
            var candidates: [String] = []
            switch params?["candidates"] {
            case nil, is NSNull: break
            case let list as [Any]:
                for item in list.prefix(AgentPaneGitHubCheckout.maximumCandidates) {
                    guard let path = item as? String, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { return nil }
                    candidates.append(path)
                }
            default: return nil
            }
            self = .checkout(repo: repo, candidates: candidates, key: key)
        default: return nil
        }
    }

    public var method: String {
        switch self {
        case .status: "github.status"
        case .connect, .addAccount: "github.connect"
        case .repos: "github.repos.list"
        case .checkout: "github.repos.checkout"
        case .cloneURL: "repo.clone"
        }
    }

    /// The reply. Connect opens the person's browser, so only on their own click (`gesture`).
    @MainActor func reply(_ gitHub: AgentPaneGitHub?, gesture: () -> Bool) async -> [String: Any] {
        guard let gitHub else {
            // A preview or a pane without Cloud still explains why GitHub is unavailable.
            if case .status = self { return Self.statusReply(.unavailable(.unreachable)) }
            return Self.unavailableReply(.unreachable)
        }
        switch self {
        case .status:
            return Self.statusReply(await gitHub.status(), progress: gitHub.changes?.phase ?? .idle)
        case .connect, .addAccount:
            guard gesture() else { return AgentPaneModel.transportFailure(.gestureRequired) }
            let connected: AgentPaneGitHubConnect
            if case .connect(let repo) = self { connected = await gitHub.connect(repo) } else { connected = await (gitHub.addAccount ?? { await gitHub.connect(nil) })() }
            switch connected {
            // The installation page, or the cmux sign-in for a person signed out, opened.
            case .opened: return AgentPaneReply.success(["opened": true])
            // Nothing to open: the team is connected already (the picker reads `github.status` again).
            case .alreadyConnected: return AgentPaneReply.success(["opened": false])
            case .unavailable(let reason): return Self.unavailableReply(reason)
            case .failed(let message):
                return AgentPaneReply.failure(code: "github.connect_failed", message: message.isEmpty ? AgentPaneModel.gitHubUnavailableMessage : message)
            }
        case .repos(let query):
            switch await gitHub.repos(query) {
            case .success(let listed):
                gitHub.sizes.note(listed.repos)
                let repos: [[String: Any]] = listed.repos.map { repo in
                    ["full_name": repo.fullName, "private": repo.isPrivate, "default_branch": repo.defaultBranch.map { $0 as Any } ?? NSNull(),
                     "size_kb": repo.sizeKb.map { $0 as Any } ?? NSNull()]
                }
                return AgentPaneReply.success(["repos": repos, "truncated": listed.truncated])
            case .failure(.notConnected):
                return AgentPaneReply.failure(code: "github.not_connected", message: AgentPaneModel.gitHubNotConnectedMessage)
            case .failure(.unavailable):
                return AgentPaneReply.failure(code: "github.unavailable", message: AgentPaneModel.gitHubUnavailableMessage)
            }
        case .checkout, .cloneURL:
            // The pane model answers it with the chat's worktree (``AgentPaneGitWriteReply``).
            return AgentPaneModel.unsupported(method)
        }
    }

    /// `{state, repos_scope, reason, problem, message}`: `reason` (`signed_out`, `not_configured`, `unreachable`) only when
    /// unavailable, so the picker can still offer Connect GitHub. A not-connected state that needs more than "Connect" says
    /// so in `problem` (`needs_reauth`, `linking`, `error`, `link_refused`) and `message`, the words the Connect row shows;
    /// both are null otherwise.
    ///
    /// `progress` is where the app's own connect stands (``CloudGitHubChanges/Phase``): `idle`, `on_github` (GitHub's page
    /// is open in the app's sheet), `finishing`, `connected` (with `account`) or `requested` (with `account`: the
    /// organization asked). The picker shows it in place of Connect, so nothing outside the app says what happened.
    /// `pending_approval`: an organization owner has the request (the picker's approval card).
    @MainActor static func statusReply(_ status: CloudGitHubPicker.Status, progress: CloudGitHubChanges.Phase = .idle) -> [String: Any] {
        let (step, account) = progressFields(progress)
        return AgentPaneReply.success(["state": status.state, "repos_scope": status.reposScope.map { $0 as Any } ?? NSNull(),
                                       "reason": status.reason.map { $0.rawValue as Any } ?? NSNull(),
                                       "problem": status.problem.map { $0 as Any } ?? NSNull(),
                                       "message": message(for: status).map { $0 as Any } ?? NSNull(),
                                       "progress": step, "account": account.map { $0 as Any } ?? NSNull(),
                                       "pending_approval": status.problem == "requested"])
    }

    /// The wire names of ``CloudGitHubChanges/Phase``.
    nonisolated static func progressFields(_ phase: CloudGitHubChanges.Phase) -> (String, String?) {
        switch phase {
        case .idle: ("idle", nil)
        case .onGitHub: ("on_github", nil)
        case .finishing: ("finishing", nil)
        case .connected(let account): ("connected", account)
        case .requested(let owner): ("requested", owner)
        }
    }

    /// The words for a Connect GitHub state that is not a plain "not connected": the server's reason or the API's own when
    /// it gave one, else the app's.
    @MainActor static func message(for status: CloudGitHubPicker.Status) -> String? {
        switch status {
        case .needsReauth(let detail): detail ?? AgentPaneModel.gitHubReauthMessage
        case .linking: AgentPaneModel.gitHubConnectPendingMessage
        case .error: AgentPaneModel.gitHubConnectionErrorMessage
        case .linkRefused(let reason): reason ?? AgentPaneModel.gitHubLinkExpiredMessage
        case .requested(let owner): AgentPaneModel.gitHubRequestedMessage(owner: owner)
        case .ready, .notConnected, .unavailable: nil
        }
    }

    /// Connect GitHub where GitHub is unavailable: `github.signed_out`, `github.not_configured` or `github.unavailable`.
    @MainActor static func unavailableReply(_ reason: CloudGitHubPicker.Unavailable) -> [String: Any] {
        switch reason {
        case .signedOut: AgentPaneReply.failure(code: "github.signed_out", message: AgentPaneModel.gitHubSignedOutMessage)
        case .notConfigured: AgentPaneReply.failure(code: "github.not_configured", message: AgentPaneModel.gitHubNotConfiguredMessage)
        case .unreachable: AgentPaneReply.failure(code: "github.unavailable", message: AgentPaneModel.gitHubUnavailableMessage)
        }
    }
}

/// What answers the picker's GitHub methods for every pane: the signed-in person's session, in the team a
/// Cloud start's machine is made in (``CloudGitHubPicker``). The App sets it.
public struct AgentPaneGitHub {
    /// `state` (`ready`, `not_connected`, `unavailable`), `repos_scope` (`all`, `selected`, nil) and why unavailable.
    public var status: @MainActor () async -> CloudGitHubPicker.Status
    /// Connect GitHub; its `repo` (`owner/name`) is a Cloud start card's repository, nil for the folder menu (#55104).
    public var connect: @MainActor (String?) async -> AgentPaneGitHubConnect
    public var repos: @MainActor (String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure>
    /// The sizes the repos list gave, shared by every pane's copy: a Cloud start in a picked repository is sized from them.
    public let sizes: AgentPaneGitHubRepoSizes
    /// A picked repository's checkout on this Mac, for a chat here (nil: none offered, the page keeps it a Cloud pick).
    public let checkout: AgentPaneGitHubCheckout?
    /// The installs the app finished (``CloudAuth/gitHubChanges``): each one, the page reads GitHub again. Nil: none.
    public let changes: CloudGitHubChanges?
    /// The picker's Add organization (``AgentPaneGitHubRequest/addAccount``); nil: Connect GitHub answers it.
    public var addAccount: (@MainActor () async -> AgentPaneGitHubConnect)?

    public init(status: @escaping @MainActor () async -> CloudGitHubPicker.Status,
                connect: @escaping @MainActor () async -> AgentPaneGitHubConnect,
                repos: @escaping @MainActor (String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure>,
                sizes: AgentPaneGitHubRepoSizes = AgentPaneGitHubRepoSizes(),
                checkout: AgentPaneGitHubCheckout? = nil, changes: CloudGitHubChanges? = nil) {
        self.init(status: status, connectRepo: { _ in await connect() }, repos: repos, sizes: sizes, checkout: checkout, changes: changes)
    }

    public init(status: @escaping @MainActor () async -> CloudGitHubPicker.Status,
                connectRepo: @escaping @MainActor (String?) async -> AgentPaneGitHubConnect,
                repos: @escaping @MainActor (String?) async -> Result<CloudGitHubRepos, CloudGitHubRepos.Failure>,
                sizes: AgentPaneGitHubRepoSizes = AgentPaneGitHubRepoSizes(),
                checkout: AgentPaneGitHubCheckout? = nil, changes: CloudGitHubChanges? = nil) {
        (self.status, self.connect, self.repos, self.sizes, self.checkout, self.changes) = (status, connectRepo, repos, sizes, checkout, changes)
    }

    /// The App's: `picker` reads and connects as the person in the team a Cloud start's machine is made in, `open`
    /// opens the page its Connect GitHub answers in the person's browser, and a person signed out gets the app's own
    /// cmux sign-in (``CloudAuth/beginSignIn(selectAccount:)``, which joins one already in progress). Once that sign-in
    /// succeeds, the same connect request is replayed so the person does not need to press Connect again.
    @MainActor public static func live(_ picker: CloudGitHubPicker, open: @escaping @MainActor (URL) -> Void) -> AgentPaneGitHub {
        var gitHub = AgentPaneGitHub(status: { await picker.status() },
                                     connectRepo: { repo in
                                         AgentPaneGitHubConnect(await picker.connect(repo: repo), open: open) {
                                             _ = Self.signInAndRetry(beginSignIn: { picker.auth.beginSignIn() },
                                                                     connect: { await picker.connect(repo: repo) }, open: open,
                                                                     connected: { picker.auth.gitHubChanges.recordConnected() })
                                         }
                                     },
                                     repos: { await picker.repos(query: $0) },
                                     checkout: AgentPaneGitHubCheckout { await picker.cloneToken(repo: $0)?.token },
                                     changes: picker.auth.gitHubChanges)
        gitHub.addAccount = {
            AgentPaneGitHubConnect(await picker.connect(addAccount: true), open: open) {
                _ = Self.signInAndRetry(beginSignIn: { picker.auth.beginSignIn() },
                                        connect: { await picker.connect(addAccount: true) }, open: open,
                                        connected: { picker.auth.gitHubChanges.recordConnected() })
            }
        }
        return gitHub
    }

    /// Starts cmux sign-in for a signed-out Connect GitHub request and replays the request after it succeeds.
    /// The task is returned so tests and callers that own the flow can observe its completion.
    @MainActor @discardableResult
    static func signInAndRetry(beginSignIn: @escaping @MainActor () -> Task<Bool, Never>,
                               connect: @escaping @MainActor () async -> CloudGitHubPicker.Connect,
                               open: @escaping @MainActor (URL) -> Void,
                               connected: @escaping @MainActor () -> Void = {}) -> Task<Void, Never> {
        let signIn = beginSignIn()
        return Task { await finishSignInAndRetry(signIn: signIn, connect: connect, open: open, connected: connected) }
    }

    @MainActor
    private static func finishSignInAndRetry(signIn: Task<Bool, Never>,
                                             connect: @escaping @MainActor () async -> CloudGitHubPicker.Connect,
                                             open: @escaping @MainActor (URL) -> Void,
                                             connected: @escaping @MainActor () -> Void) async {
        guard await signIn.value else { return }
        switch await connect() {
        case .open(let page): open(page)
        case .connected: connected()
        case .unavailable, .failed: break
        }
    }
}

/// How Connect GitHub ended.
public enum AgentPaneGitHubConnect: Equatable, Sendable {
    /// The App's installation page opened in the person's browser.
    case opened
    case alreadyConnected
    /// Signed out with no sign-in to start, no App here, or no answer from the status route.
    case unavailable(CloudGitHubPicker.Unavailable)
    /// The words the person reads (the connect failed).
    case failed(String)

    /// The words the person reads for a connect that opened nothing; empty when it opened or was connected already.
    @MainActor public var message: String {
        switch self {
        case .opened, .alreadyConnected: ""
        case .unavailable(.signedOut): AgentPaneModel.gitHubSignedOutMessage
        case .unavailable(.notConfigured): AgentPaneModel.gitHubNotConfiguredMessage
        case .unavailable(.unreachable): AgentPaneModel.gitHubUnavailableMessage
        case .failed(let message): message.isEmpty ? AgentPaneModel.gitHubUnavailableMessage : message
        }
    }

    /// The shared Connect GitHub's result (`accounts.githubConnect`, GitHubConnections' `connectResult()`):
    /// `pending` once the installation page opened, `connected` when there was nothing to open, else its detail.
    public init(_ result: Result<[String: ActionResultValue], ActionWorkFailure>) {
        switch result {
        case .success(let fields) where fields["status"] == .string("pending"): self = .opened
        case .success(let fields) where fields["status"] == .string("connected"): self = .alreadyConnected
        case .success(let fields):
            if case .string(let detail)? = fields["detail"] { self = .failed(detail) } else { self = .failed("") }
        case .failure(let failure): self = .failed(failure.message)
        }
    }

    /// The picker's own Connect GitHub (``CloudGitHubPicker/connect()``): its page opened with `open`, a person signed
    /// out sent to `signIn` (the cmux sign-in, then the same request is replayed), or why neither.
    @MainActor public init(_ connect: CloudGitHubPicker.Connect, open: (URL) -> Void, signIn: (@MainActor () -> Void)? = nil) {
        switch connect {
        case .open(let url): open(url); self = .opened
        case .connected: self = .alreadyConnected
        case .unavailable(.signedOut) where signIn != nil: signIn?(); self = .opened
        case .unavailable(let reason): self = .unavailable(reason)
        case .failed: self = .failed("")
        }
    }
}

/// A chat folder that names a repository instead of a folder on this Mac: `github:owner/name`, or `git:URL` (Add
/// project's Git URL with Cloud picked: an https Git URL on any host, GitLab too).
/// Only a Cloud start takes one (its machine clones the repository); a chat here is refused.
public nonisolated struct AgentPaneGitHubFolder {
    public nonisolated init() {}
    public static let prefix = "github:"
    public static let gitURLPrefix = "git:"
    /// The refusal's code for a chat here that names one (`session/new`'s `cwd`, `workspace.useFolder`).
    public static let cloudOnlyReason = "github.cloud_only"

    public static func isGitHub(_ folder: String) -> Bool { folder.hasPrefix(prefix) }

    /// A folder only a Cloud machine's clone gives: `github:` or `git:`.
    public static func isRepository(_ folder: String) -> Bool { isGitHub(folder) || folder.hasPrefix(gitURLPrefix) }

    /// `owner/name` of `github:owner/name`, or the URL of `git:URL` when Rust's `cloud_machine_repo_parse` reads a
    /// repository in it (``CloudMachineRepo/parse(_:)``); nil for any other text, a bad name or URL included.
    public static func repository(_ folder: String) -> String? {
        if folder.hasPrefix(gitURLPrefix) {
            let url = String(folder.dropFirst(gitURLPrefix.count))
            return (try? CloudMachineRepo.parse(url)) == nil ? nil : url
        }
        guard isGitHub(folder) else { return nil }
        let name = String(folder.dropFirst(prefix.count))
        return CloudGitHubRepos.isFullName(name) ? name : nil
    }
}

public extension AgentPaneView {
    /// Gives the page `gitHub` (``AgentPaneModel/gitHub``) and follows its finished installs (``AgentPaneGitHub/changes``).
    func useGitHub(_ gitHub: AgentPaneGitHub?) {
        model.gitHub = gitHub
        gitHubChangeObservation = gitHub?.changes.map { changes in
            Task { [weak self] in
                for await _ in ObservationStream({ changes.count }).dropFirst() { self?.gitHubChanged() }
            }
        }
    }

    /// GitHub changed under the page (the app finished an install GitHub handed back to it, #46018): the folder menu
    /// reads `github.status` and the repositories again. No repository or account data goes with it.
    func gitHubChanged() {
        deliver([AgentPageEvent(kind: "github.changed", value: .null)],
                scripts: ["window.dispatchEvent(new Event('cmux-github-changed'));"])
    }
}
