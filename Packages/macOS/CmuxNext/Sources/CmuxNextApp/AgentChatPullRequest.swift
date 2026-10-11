import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import Observation

/// Reads the pull request of a folder's branch with the user's GitHub CLI (cx-tcwj):
/// `gh pr view --json url,number,state,isDraft,statusCheckRollup` in the folder. Nil when gh is not
/// installed, the branch has no pull request, or gh does not answer in time; it never prompts.
nonisolated struct AgentChatPullRequestReader: Sendable {
    /// `gh`'s path; nil looks in the App's PATH and the usual install folders.
    var gh: String?
    var timeout: Duration = .seconds(30)

    /// Folders an app launched from Finder lacks on its PATH, where gh usually is.
    static let installFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    func read(in folder: String) async -> AgentPanePullRequest? {
        guard let gh = gh ?? Self.findGitHubCLI() else { return nil }
        let timeout = timeout
        return await Task.detached(priority: .utility) {
            Self.run(gh, in: folder, timeout: timeout).flatMap(AgentPanePullRequest.init(ghView:))
        }.value
    }

    static func findGitHubCLI(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + installFolders
        return folders.filter { $0.hasPrefix("/") }.map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The process, for the deadline.
    private final class Held: @unchecked Sendable {
        let process = Process()
    }

    private static func run(_ gh: String, in folder: String, timeout: Duration) -> Data? {
        let held = Held(), process = held.process
        let app = ProcessInfo.processInfo.environment
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["pr", "view", "--json", "url,number,state,isDraft,statusCheckRollup"]
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var environment = ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GIT_TERMINAL_PROMPT": "0",
                           "PATH": ([app["PATH"] ?? "/usr/bin:/bin"] + installFolders).joined(separator: ":")]
        environment["HOME"] = app["HOME"]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = DemandTimer(owner: "header-pull-request")
        deadline.schedule(after: timeout) { if held.process.isRunning { held.process.terminate() } }
        defer { deadline.cancel() }
        // concurrency-allow: run is called only inside read's detached utility task; gh's answer is one small JSON object.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        // concurrency-allow: run is called only inside read's detached utility task, bounded by the deadline above.
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// The chat header's pull request chip, per chat (cx-tcwj): the header state reads ``badge(cwd:)``
/// while its watch observes it, so the answer is pushed to the page when it lands. A folder is
/// asked again only when the header is read after its answer is older than `freshness`; nothing polls.
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

    init(reader: AgentChatPullRequestReader = AgentChatPullRequestReader(), freshness: Duration = .seconds(60)) {
        self.reader = reader
        self.freshness = freshness
    }

    /// The pull request of `cwd`'s branch as last read (nil: none, or not read yet); asks again
    /// when there is no fresh answer for `cwd`.
    func badge(cwd: String?) -> AgentPanePullRequest? {
        guard let cwd else { return nil }
        let known = answer?.cwd == cwd ? answer : nil
        if asking != cwd, known.map({ ContinuousClock.now - $0.at > freshness }) ?? true {
            asking = cwd
            let reader = reader
            // task-owner: one gh read per stale folder; its answer lands on this chat's state.
            Task { [weak self] in
                let badge = await reader.read(in: cwd)
                guard let self, asking == cwd else { return }
                asking = nil
                answer = Answer(cwd: cwd, badge: badge, at: .now)
            }
        }
        return known?.badge
    }
}
