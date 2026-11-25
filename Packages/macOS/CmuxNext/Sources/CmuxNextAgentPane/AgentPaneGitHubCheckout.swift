import CmuxNextCompat
import CmuxNextDaemon
public import Foundation

/// A GitHub repository picked from a chat on this Mac's folder menu, as a folder on this Mac
/// (`github.repos.checkout`, ``AgentPaneGitHubRequest/checkout(repo:candidates:)``): the checkout this Mac
/// already has, else a fresh clone under ``root`` (`~/cmux/repos/<owner>/<name>`). The page then makes the
/// chat's worktree from it (`git.worktree.create`), as New Worktree does.
///
/// - An existing checkout is one of the folders the page knows for that repository (its recent projects
///   whose remote names it), or the default clone folder, whose remote git confirms here: the page's word
///   alone never names a folder.
/// - A clone of a private repository uses a token the cmux GitHub App mints for that one repository
///   (``CloudGitHubCloneToken``), handed to that one git through its environment and a credential helper
///   given on the command line, so it is in no argv, no remote URL and no config on disk; without one (no
///   GitHub connection, or the mint refused) git uses the person's own credentials, never prompting.
/// - A clone goes into a hidden sibling folder and is renamed into place only once it finished, so a failed
///   or cancelled clone never leaves a half checkout where the next pick would find it.
/// - Two picks of the same repository share one clone.
@MainActor public final class AgentPaneGitHubCheckout {
    /// One git run: its arguments, folder and extra environment in, its exit status and output out (nil: no
    /// answer, timed out or did not start).
    public typealias Git = @Sendable (_ arguments: [String], _ folder: String?, _ environment: [String: String], _ timeout: Duration) async -> GitRun?
    /// A token to clone `owner/name`, or nil.
    public typealias Token = @MainActor (_ repo: String) async -> String?

    public nonisolated struct GitRun: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public init(status: Int32, stdout: String) { (self.status, self.stdout) = (status, stdout) }
    }

    public nonisolated struct Checkout: Sendable, Equatable {
        /// The checkout's top folder.
        public var path: String
        /// Cloned now, not found on this Mac.
        public var cloned: Bool
    }

    public nonisolated enum Failure: Error, Sendable, Equatable {
        /// git could not clone it: no access with either credential, offline, or git is missing.
        case cloneFailed
        /// Every folder the clone could go in is taken by something else.
        case noFolder
    }

    /// Where clones go: `<root>/<owner>/<name>`.
    public let root: URL
    private let git: Git
    private let token: Token
    private var running: [String: Task<Result<Checkout, Failure>, Never>] = [:]

    /// How long a clone may take: a large repository over a slow link is minutes, not seconds.
    nonisolated static let cloneTimeout: Duration = .seconds(30 * 60)
    /// How long a read of a folder's remote may take.
    nonisolated static let readTimeout: Duration = .seconds(10)
    /// The environment variable the credential helper reads the token from.
    nonisolated static let tokenVariable = "CMUX_GITHUB_CLONE_TOKEN"
    /// At most this many folders the page names are checked.
    public nonisolated static let maximumCandidates = 16

    public init(root: URL, token: @escaping Token, git: @escaping Git) {
        (self.root, self.token, self.git) = (root, token, git)
    }

    /// The App's: clones under `~/cmux/repos`, git from the system.
    public convenience init(token: @escaping Token) {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        self.init(root: home.appending(path: "cmux/repos", directoryHint: .isDirectory), token: token, git: Self.systemGit)
    }

    /// `repo`'s checkout on this Mac: one of `candidates` (or the default clone folder) whose remote is
    /// `repo`, else a new clone.
    public func checkout(repo: String, candidates: [String]) async -> Result<Checkout, Failure> {
        if let task = running[repo.lowercased()] { return await task.value }
        let task = Task { await self.resolve(repo: repo, candidates: candidates) }
        running[repo.lowercased()] = task
        defer { running[repo.lowercased()] = nil }
        return await task.value
    }

    private func resolve(repo: String, candidates: [String]) async -> Result<Checkout, Failure> {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return .failure(.cloneFailed) }
        let owner = root.appending(path: parts[0], directoryHint: .isDirectory)
        let defaults = [parts[1]] + (2...9).map { "\(parts[1])-\($0)" }
        let defaultFolders = defaults.map { owner.appending(path: $0, directoryHint: .isDirectory).path }
        var seen = Set<String>()
        for folder in candidates.prefix(Self.maximumCandidates) + defaultFolders where seen.insert(folder).inserted {
            if let top = await checkoutTop(folder, of: repo) { return .success(Checkout(path: top, cloned: false)) }
        }
        // The first default folder nothing else holds.
        guard let destination = await Self.firstFree(defaultFolders) else { return .failure(.noFolder) }
        guard await Self.makeFolder(owner) else { return .failure(.cloneFailed) }
        let partial = owner.appending(path: ".\(parts[1]).cloning-\(UUID().uuidString)", directoryHint: .isDirectory).path
        let url = "https://github.com/\(repo).git"
        var cloned = false
        // The person's own git is tried after the token only when git answered (no access with the token): a clone that
        // timed out or never started is not run a second time on the same click.
        var retry = true
        if let token = await token(repo) {
            let run = await clone(url, into: partial, environment: [Self.tokenVariable: token], helper: true)
            cloned = run?.status == 0
            retry = run != nil
        }
        if !cloned, retry {
            await Self.remove(partial)
            cloned = await clone(url, into: partial, environment: [:], helper: false)?.status == 0
        }
        let moved = cloned ? await Self.move(partial, to: destination) : false
        // A failed or cancelled clone, or one another clone beat into place, leaves nothing behind.
        await Self.remove(partial)
        guard cloned else { return .failure(.cloneFailed) }
        guard moved else {
            // Another clone of it landed there meanwhile (another app): use that one when it is this repository.
            if let top = await checkoutTop(destination, of: repo) { return .success(Checkout(path: top, cloned: false)) }
            return .failure(.noFolder)
        }
        return .success(Checkout(path: destination, cloned: true))
    }

    // The disk work, off the main thread.
    @concurrent nonisolated static func firstFree(_ folders: [String]) async -> String? {
        folders.first { !FileManager.checked.fileExists(atPath: $0) }
    }

    @concurrent nonisolated static func makeFolder(_ folder: URL) async -> Bool {
        (try? FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
    }

    @concurrent nonisolated static func remove(_ path: String) async {
        try? FileManager.checked.removeItem(atPath: path)
    }

    @concurrent nonisolated static func move(_ path: String, to destination: String) async -> Bool {
        (try? FileManager.checked.moveItem(atPath: path, toPath: destination)) != nil
    }

    @concurrent nonisolated static func isFolder(_ path: String) async -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.checked.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// The clone's git run; nil when it timed out or did not start.
    private func clone(_ url: String, into folder: String, environment: [String: String], helper: Bool) async -> GitRun? {
        // The helper answers only git's `get`, with the token from this git's own environment: an empty
        // `credential.helper=` first drops the person's helpers, so the token is not stored by one of them.
        let credential = helper
            ? ["-c", "credential.helper=", "-c", "credential.helper=!f() { test \"$1\" = get && echo username=x-access-token && echo \"password=$\(Self.tokenVariable)\"; }; f"]
            : []
        let arguments = credential + ["clone", "--quiet", "--", url, folder]
        return await git(arguments, nil, environment, Self.cloneTimeout)
    }

    /// `folder`'s checkout top folder when one of its remotes is `repo`; nil otherwise (no folder, no git, another repository).
    func checkoutTop(_ folder: String, of repo: String) async -> String? {
        guard folder.hasPrefix("/"), !folder.contains("\0"), await Self.isFolder(folder),
              let remotes = await git(["-C", folder, "config", "--get-regexp", "^remote\\..*\\.url$"], nil, [:], Self.readTimeout),
              remotes.status == 0,
              remotes.stdout.split(separator: "\n").contains(where: { line in
                  line.split(separator: " ", maxSplits: 1).last.map { Self.gitHubRepository(ofRemote: String($0)) == repo.lowercased() } ?? false
              }),
              let top = await git(["-C", folder, "rev-parse", "--show-toplevel"], nil, [:], Self.readTimeout), top.status == 0 else { return nil }
        let path = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    /// `owner/name`, lowercased, of a github.com remote URL (`https://github.com/o/n(.git)`, `git@github.com:o/n(.git)`,
    /// `ssh://git@github.com/o/n`); nil for any other. An ssh host alias (`git@github-work:o/n`) is not read as github.com:
    /// such a checkout is not found, and the pick clones its own copy under ``root``.
    nonisolated static func gitHubRepository(ofRemote remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("git@github.com:") {
            text = String(text.dropFirst("git@github.com:".count))
        } else if let url = URL(string: text), ["https", "http", "ssh", "git"].contains(url.scheme ?? ""), url.host == "github.com" {
            text = String(url.path.drop(while: { $0 == "/" }))
        } else {
            return nil
        }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text.split(separator: "/").count == 2 ? text : nil
    }

    /// git as the system has it, never prompting: the App's environment (PATH, HOME, the ssh agent), git's prompts off.
    public nonisolated static let systemGit: Git = { arguments, folder, extra, timeout in
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "never"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment.merge(extra) { _, new in new }
        let executable = URL(fileURLWithPath: "/usr/bin/git")
        guard let result = try? await ProcessRunner.run(executable: executable, arguments: (folder.map { ["-C", $0] } ?? []) + arguments,
                                                        environment: environment, timeout: timeout, clock: ContinuousClock()) else { return nil }
        return GitRun(status: result.status, stdout: String(decoding: result.stdout, as: UTF8.self))
    }
}
