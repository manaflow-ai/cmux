import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import Observation

/// Reads the pull request of a folder's branch with the user's GitHub CLI (cx-tcwj):
/// `gh pr view --json` ``AgentPanePullRequest/fields`` in the folder. Nil when gh is not installed,
/// the branch has no pull request, or gh does not answer in time; it never prompts.
nonisolated struct AgentChatPullRequestReader: Sendable {
    /// `gh`'s path; nil looks in the App's PATH and the usual install folders.
    var gh: String?
    var timeout: Duration = .seconds(30)
    /// The App's environment, from which gh gets the user's GitHub settings (``githubVariables``).
    var environment: [String: String] = ProcessInfo.processInfo.environment

    init(gh: String? = nil, timeout: Duration = .seconds(30), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.gh = gh
        self.timeout = timeout
        self.environment = environment
    }

    /// Folders an app launched from Finder lacks on its PATH, where gh usually is.
    static let installFolders = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// The user's GitHub settings gh reads from its environment: a token-only or proxied setup has
    /// no chip without them (cx-mb1e0).
    static let githubVariables = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST",
                                  "GH_CONFIG_DIR", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy"]
    /// gh runs here, two at a time, never on the cooperative pool: each may wait up to `timeout`,
    /// and restoring many chats offline must not fill the pool (cx-mb1e0).
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "header-pull-request"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    func read(in folder: String) async -> AgentPanePullRequest? {
        await read(arguments: ["pr", "view", "--json", AgentPanePullRequest.fields], in: folder)
    }

    /// The pull request at `url` (`gh pr view <url>`), wherever its branch is checked out.
    func read(url: String) async -> AgentPanePullRequest? {
        await read(arguments: ["pr", "view", url, "--json", AgentPanePullRequest.fields], in: nil)
    }

    private func read(arguments: [String], in folder: String?) async -> AgentPanePullRequest? {
        guard let gh = gh ?? Self.findGitHubCLI(environment) else { return nil }
        let timeout = timeout, environment = Self.environment(environment)
        return await withCheckedContinuation { continuation in
            Self.queue.addOperation {
                continuation.resume(returning: Self.run(gh, arguments: arguments, in: folder, environment: environment, timeout: timeout)
                    .flatMap(AgentPanePullRequest.init(ghView:)))
            }
        }
    }

    /// gh's environment: no prompts, the App's PATH and gh's install folders, HOME, and the user's
    /// GitHub settings.
    static func environment(_ app: [String: String]) -> [String: String] {
        var environment = ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GIT_TERMINAL_PROMPT": "0",
                           "PATH": ([app["PATH"] ?? "/usr/bin:/bin"] + installFolders).joined(separator: ":")]
        environment["HOME"] = app["HOME"]
        for key in githubVariables { environment[key] = app[key] }
        return environment
    }

    static func findGitHubCLI(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + installFolders
        return folders.filter { $0.hasPrefix("/") }.map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The process, for the deadline.
    private final class Held: @unchecked Sendable {
        let process = Process()
    }

    private static func run(_ gh: String, arguments: [String], in folder: String?, environment: [String: String],
                            timeout: Duration) -> Data? {
        let held = Held(), process = held.process
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
        process.environment = environment
        // A file, not a pipe: a child gh left holding its output cannot keep this read (and one of
        // the queue's two runs) waiting past the deadline.
        let file = FileManager.default.temporaryDirectory.appending(path: "cmux-gh-pr-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let output = try? FileHandle(forWritingTo: file) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        try? output.close()
        let deadline = DemandTimer(owner: "header-pull-request")
        deadline.schedule(after: timeout) { if held.process.isRunning { held.process.terminate() } }
        defer { deadline.cancel() }
        // concurrency-allow: run is called only on read's own operation queue, bounded by the deadline above.
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: file)
    }
}

/// The chat header's pull request chip, per chat (cx-tcwj): the header state reads ``badge(cwd:)``
/// while its watch observes it, so the answer is pushed to the page when it lands. A folder is
/// asked again when the header is read after its answer is older than `freshness`, and on its own
/// after `freshness` while its checks run, so the dot turns when they finish; nothing else polls.
@MainActor @Observable
final class AgentChatPullRequest {
    private struct Answer {
        var cwd: String
        var badge: AgentPanePullRequest?
        var at: ContinuousClock.Instant
    }

    private var answer: Answer?
    @ObservationIgnored private let reader: AgentChatPullRequestReader
    @ObservationIgnored private let freshness: Duration
    /// The folder being asked now.
    @ObservationIgnored private var asking: String?
    /// A turn ended while that ask ran: its answer may predate the agent's push, so ask once more.
    @ObservationIgnored private var askAfter = false
    /// Asks again while the answer's checks run.
    @ObservationIgnored private let refresh = DemandTimer(owner: "header-pull-request-checks")

    init(reader: AgentChatPullRequestReader = AgentChatPullRequestReader(), freshness: Duration = .seconds(60)) {
        self.reader = reader
        self.freshness = freshness
    }

    /// The pull request of `cwd`'s branch as last read (nil: none, or not read yet); asks again
    /// when there is no fresh answer for `cwd`.
    func badge(cwd: String?) -> AgentPanePullRequest? {
        guard let cwd else { return nil }
        let known = answer?.cwd == cwd ? answer : nil
        if asking != cwd, known.map({ ContinuousClock.now - $0.at > freshness }) ?? true { ask(cwd) }
        return known?.badge
    }

    /// Asks again for the folder last asked about, fresh or not: a turn ended, and the agent may
    /// have created the pull request or pushed to it (cx-mb1e0).
    func askAgain() {
        if asking != nil { askAfter = true } else if let cwd = answer?.cwd { ask(cwd) }
    }

    private func ask(_ cwd: String) {
        asking = cwd
        refresh.cancel()
        let reader = reader
        // task-owner: one gh read per stale folder; its answer lands on this chat's state.
        Task { [weak self] in
            let badge = await reader.read(in: cwd)
            guard let self, asking == cwd else { return }
            asking = nil
            answer = Answer(cwd: cwd, badge: badge, at: .now)
            if askAfter {
                askAfter = false
                return ask(cwd)
            }
            guard badge?.checks.state == "pending" else { return }
            refresh.schedule(after: freshness) { @MainActor [weak self] in
                guard let self, answer?.cwd == cwd, asking == nil else { return }
                ask(cwd)
            }
        }
    }
}
