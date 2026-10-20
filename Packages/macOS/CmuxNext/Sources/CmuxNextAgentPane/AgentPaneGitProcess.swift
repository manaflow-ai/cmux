import CmuxNextCompat
import Foundation

/// One `git` run for the Changes view's writes (cx-tcwj): `/usr/bin/git` with a plain environment,
/// no prompt for credentials, and a deadline that holds even when a child git started (for example,
/// a clean filter) keeps its output open.
nonisolated enum AgentPaneGitProcess {
    typealias Override = (key: String, value: String)

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
        let outcome = await output(arguments, input: input, timeout: timeout, network: network, allowRepositoryPrograms: true)
        return outcome.status == 0 ? nil : outcome.message
    }

    /// What one run printed, output and errors together, and its exit status (nil: it did not run
    /// or did not finish in time).
    struct Outcome {
        var status: Int32?
        var data: Data

        var text: String { String(decoding: data, as: UTF8.self) }

        init(status: Int32?, text: String) {
            self.status = status
            data = Data(text.utf8)
        }

        init(status: Int32?, data: Data) {
            self.status = status
            self.data = data
        }

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
                       input: Data? = nil, timeout: Duration, network: Bool = false,
                       allowRepositoryPrograms: Bool = false) async -> Outcome {
        let overrides: [Override]
        if allowRepositoryPrograms {
            overrides = []
        } else if let folder = repositoryFolder(arguments: arguments, directory: directory) {
            switch await filterOverrides(in: folder, timeout: timeout) {
            case .ready(let configured): overrides = configured
            case .failed(let outcome): return outcome
            }
        } else {
            overrides = []
        }
        let environment = network
            ? networkEnvironment(overrides: overrides)
            : environment(overrides: overrides, denyTransports: !allowRepositoryPrograms,
                          allowSystemConfiguration: allowRepositoryPrograms)
        let safeArguments = executable == "/usr/bin/git" && !allowRepositoryPrograms ? safeReadConfiguration + arguments : arguments
        return await Task.detached(priority: .userInitiated) {
            runSync(Command(executable: executable, arguments: safeArguments, directory: directory, environment: environment),
                    input: input, timeout: timeout)
        }.value
    }

    private enum FilterPreparation {
        case ready([Override])
        case failed(Outcome)
    }

    private static let safeReadConfiguration = [
        "-c", "log.showSignature=false",
        "-c", "diff.submodule=short",
        "-c", "core.attributesFile=/dev/null",
        "-c", "diff.orderFile=/dev/null",
    ]

    private static func filterOverrides(in folder: String, timeout: Duration) async -> FilterPreparation {
        let pattern = #"^filter\..*\.(clean|smudge|process|required)$"#
        let command = Command(
            executable: "/usr/bin/git",
            arguments: safeReadConfiguration + ["-C", folder, "config", "--null", "--name-only", "--get-regexp", pattern],
            directory: nil,
            environment: environment(denyTransports: true)
        )
        let outcome = await Task.detached(priority: .userInitiated) { runSync(command, input: nil, timeout: timeout) }.value
        if outcome.status == 1, outcome.data.isEmpty { return .ready([]) }
        guard outcome.status == 0, let overrides = parseFilterOverrides(outcome.data) else { return .failed(outcome) }
        return .ready(overrides)
    }

    private static func parseFilterOverrides(_ data: Data) -> [Override]? {
        guard data.count <= 64 * 1024, let output = String(data: data, encoding: .utf8) else { return nil }
        let settings = Set(["clean", "smudge", "process", "required"])
        var drivers: Set<String> = []
        for field in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let key = String(field)
            guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), settings.contains(String(key[key.index(after: dot)...])) else {
                return nil
            }
            let driver = String(key[key.index(key.startIndex, offsetBy: "filter.".count)..<dot])
            guard !driver.isEmpty else { return nil }
            drivers.insert(driver)
        }
        guard drivers.count <= 256 else { return nil }
        return drivers.sorted().flatMap { driver in
            [("filter.\(driver).clean", ""), ("filter.\(driver).smudge", ""),
             ("filter.\(driver).process", ""), ("filter.\(driver).required", "false")]
        }
    }

    private static func repositoryFolder(arguments: [String], directory: String?) -> String? {
        if let index = arguments.firstIndex(of: "-C"), arguments.indices.contains(index + 1) {
            let folder = arguments[index + 1]
            return folder.hasPrefix("/") && !folder.contains("\0") ? folder : nil
        }
        guard let directory, directory.hasPrefix("/"), !directory.contains("\0") else { return nil }
        return directory
    }

    private struct Command {
        var executable: String, arguments: [String], directory: String?, environment: [String: String]
    }

    /// State the pipe's reader and the input's writer share with the run: the output behind a
    /// Mutex, and the input handle (FileHandle is Sendable), which only the writer touches.
    private final class Shared: Sendable {
        private let data = Mutex(Data())
        let input: FileHandle

        init(input: FileHandle) {
            self.input = input
        }

        func append(_ chunk: Data) {
            data.withLock { $0.append(chunk) }
        }

        var value: Data {
            data.withLock { $0 }
        }
    }

    private static func runSync(_ command: Command, input: Data?, timeout: Duration) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        if let directory = command.directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let output = Pipe(), stdin = Pipe()
        process.standardError = output
        process.standardOutput = output
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let shared = Shared(input: stdin.fileHandleForWriting)
        // concurrency-allow: runSync runs only inside output's detached task; each wait below has a deadline.
        let ended = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            // concurrency-allow: FileHandle calls a readability handler on its own background queue, when data is ready.
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended.signal()
            } else {
                shared.append(chunk)
            }
        }
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return Outcome(status: nil, text: error.localizedDescription)
        }
        if let input {
            // Off this thread, so a git that never reads still meets the deadline; a git that exits
            // first (a hook refused) makes this a failed write, not SIGPIPE.
            DispatchQueue.global(qos: .userInitiated).async {
                _ = fcntl(shared.input.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? shared.input.write(contentsOf: input)
                try? shared.input.close()
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        // concurrency-allow: runSync runs only inside output's detached task, bounded by the deadline.
        guard exited.wait(timeout: .now() + seconds) == .success else {
            process.terminate()
            // concurrency-allow: runSync runs only inside output's detached task; a short grace for SIGTERM.
            _ = exited.wait(timeout: .now() + 2)
            output.fileHandleForReading.readabilityHandler = nil
            return Outcome(status: nil, text: timedOutMessage)
        }
        // A child git started may still hold the pipe: wait a moment for the end of the output, no longer.
        // concurrency-allow: runSync runs only inside output's detached task; bounded to one second.
        _ = ended.wait(timeout: .now() + 1)
        output.fileHandleForReading.readabilityHandler = nil
        return Outcome(status: process.terminationStatus, data: shared.value)
    }

    /// The user's own git settings (HOME) and none of the App's environment; never a terminal
    /// prompt for credentials or a repository-selected hook/file-system monitor. The fixed
    /// `GIT_CONFIG_*` values are command-scope overrides, not inherited launcher values.
    static func environment(overrides: [Override] = [], denyTransports: Bool = false, allowSystemConfiguration: Bool = false,
                            app: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let configuration = [(key: "core.fsmonitor", value: "false"), (key: "core.hooksPath", value: "/dev/null")] + overrides
        var environment = [
            "GIT_CONFIG_COUNT": String(configuration.count),
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for (index, override) in configuration.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = override.key
            environment["GIT_CONFIG_VALUE_\(index)"] = override.value
        }
        if allowSystemConfiguration {
            environment["GIT_CONFIG_SYSTEM"] = app["GIT_CONFIG_SYSTEM"]
        } else {
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
        }
        if denyTransports {
            environment["GIT_ALLOW_PROTOCOL"] = ""
            environment["GIT_NO_LAZY_FETCH"] = "1"
        }
        if let home = app["HOME"] { environment["HOME"] = home }
        return environment
    }

    /// The plain environment, plus what reaching a remote takes: the user's tool folders (a
    /// credential helper such as `gh` or Git Credential Manager), the SSH agent, and no prompt from
    /// `gh` either.
    static func networkEnvironment(_ app: [String: String] = ProcessInfo.processInfo.environment,
                                   overrides: [Override] = []) -> [String: String] {
        var environment = environment(overrides: overrides)
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
