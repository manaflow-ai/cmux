import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One `git` run for the Changes view's writes (cx-tcwj): `/usr/bin/git` with a plain environment,
/// no prompt for credentials, and a deadline that holds even when a child git started (a filter, a
/// hook) keeps its output open.
nonisolated enum AgentPaneGitProcess {
    /// Where a write may run: the chat's folder resolved, or why not.
    enum Place: Equatable {
        case folder(String)
        case refused(String)
    }

    /// `cwd` with links resolved, when it is one of `roots` or inside one (`/` is never a root) and
    /// its repository does not hold `home`: from a dotfiles repository one request could reach every
    /// file under home.
    @concurrent static func place(_ cwd: String, roots: [String], home: String) async -> Place {
        let canonicalRoots = roots.compactMap(AcpmuxPathPolicy.canonical).filter { $0 != "/" }
        guard let folder = AcpmuxPathPolicy.canonical(cwd),
              canonicalRoots.contains(where: { AcpmuxPathPolicy.contains(root: $0, path: folder) }) else {
            return .refused(AgentPaneGitStage.outsideMessage)
        }
        let top = await output(["-C", folder, "rev-parse", "--show-toplevel"], timeout: .seconds(20))
        guard top.status == 0, let repository = AcpmuxPathPolicy.canonical(top.text.trimmingCharacters(in: .newlines)) else {
            return .refused(top.message)
        }
        if let home = AcpmuxPathPolicy.canonical(home), AcpmuxPathPolicy.contains(root: repository, path: home) {
            return .refused(homeRepositoryMessage)
        }
        return .folder(folder)
    }

    /// Nil when git exits 0, else git's message: its `fatal:` or `error:` line, else its first line
    /// (`git commit` says "nothing to commit" on its output), or why it did not run.
    static func run(_ arguments: [String], input: Data? = nil, timeout: Duration, network: Bool = false) async -> String? {
        let outcome = await output(arguments, input: input, timeout: timeout, network: network)
        return outcome.status == 0 ? nil : outcome.message
    }

    /// What one run printed, output and errors together, and its exit status (nil: it did not run
    /// or did not finish in time).
    struct Outcome {
        var status: Int32?
        var text: String

        var message: String {
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.first { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.first
                ?? status.map { "git exited \($0)" } ?? timedOutMessage
        }
    }

    /// `executable` (git unless named) with `arguments`, in `directory` when named. `network` runs
    /// reach a remote (push, `gh`): they also get the user's tool folders, for credential helpers,
    /// and the SSH agent.
    static func output(_ arguments: [String], executable: String = "/usr/bin/git", directory: String? = nil,
                       input: Data? = nil, timeout: Duration, network: Bool = false) async -> Outcome {
        let environment = network ? networkEnvironment() : environment()
        // Awaited without a thread (AsyncProcess): output and errors together, SIGTERM at the deadline
        // (SIGKILL after the grace), and the run ends at git's exit even when a child git it started keeps
        // the output open. `.finish`: a page reload or close cancels its request, but a write (and each
        // step of a write sequence: restore --staged then --worktree, diff then apply) runs to its end,
        // and a timeout returns only once git has exited and removed index.lock.
        let request = ProcessRequest(URL(fileURLWithPath: executable), arguments, environment: environment,
                                     directory: directory.map { URL(fileURLWithPath: $0) }, input: input,
                                     errorOutput: .merge, timeout: timeout, onCancel: .finish)
        do {
            let outcome = try await AsyncProcess().run(request)
            return Outcome(status: outcome.status, text: outcome.text)
        } catch ProcessFailure.launch(let message) {
            return Outcome(status: nil, text: message)
        } catch ProcessFailure.timedOut {
            return Outcome(status: nil, text: timedOutMessage)
        } catch {
            // A `.finish` run never throws CancellationError; whatever else stopped it is not a timeout.
            return Outcome(status: nil, text: stoppedMessage)
        }
    }

    /// The user's own git settings (HOME) and none of the App's environment; never a terminal
    /// prompt for credentials.
    static func environment() -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { environment["HOME"] = home }
        return environment
    }

    /// The plain environment, plus what reaching a remote takes: the user's tool folders (a
    /// credential helper such as `gh` or Git Credential Manager), the SSH agent, and no prompt from
    /// `gh` either.
    static func networkEnvironment(_ app: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = environment()
        environment["PATH"] = (toolFolders(app) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        environment["SSH_AUTH_SOCK"] = app["SSH_AUTH_SOCK"]
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        return environment
    }

    /// The App's own PATH, then the folders an app launched from Finder lacks.
    static func toolFolders(_ app: [String: String]) -> [String] {
        let home = app["HOME"] ?? NSHomeDirectory()
        let folders = (app["PATH"] ?? "").split(separator: ":").map(String.init)
            + AcpmuxEnvironment.installDirectories.map { $0.hasPrefix("~/") ? home + "/" + $0.dropFirst(2) : $0 }
        var seen: Set<String> = []
        return folders.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// git did not finish before the deadline.
    static var timedOutMessage: String {
        String(localized: "agentPane.error.gitTimedOut", defaultValue: "Git didn't finish in time.", bundle: .module)
    }

    /// git was stopped before it finished, for a reason other than its deadline.
    static var stoppedMessage: String {
        String(localized: "agentPane.error.gitStopped", defaultValue: "Git was stopped before it finished.", bundle: .module)
    }

    /// The chat's repository holds the home folder.
    static var homeRepositoryMessage: String {
        String(localized: "agentPane.error.gitHomeRepository",
               defaultValue: "This repository holds your home folder, so the Changes view won't change it.", bundle: .module)
    }

    /// The chat's session runs on another machine.
    static var remoteMessage: String {
        String(localized: "agentPane.error.gitRemote", defaultValue: "Staging and commits work only for chats on this Mac.",
               bundle: .module)
    }
}
