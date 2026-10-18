import CmuxNextCompat
import Darwin
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
        return await Task.detached(priority: .userInitiated) {
            runSync(Command(executable: executable, arguments: arguments, directory: directory, environment: environment),
                    input: input, timeout: timeout)
        }.value
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

        var text: String {
            data.withLock { String(decoding: $0, as: UTF8.self) }
        }
    }

    private static func runSync(_ command: Command, input: Data?, timeout: Duration) -> Outcome {
        let output = Pipe()
        let stdin = input.map { _ in Pipe() }
        let shared = Shared(input: stdin?.fileHandleForWriting ?? .nullDevice)
        // concurrency-allow: runSync runs only inside output's detached task; each wait below has a deadline.
        let ended = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
        let exitStatus = Mutex<Int32?>(nil)
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
        let processID: pid_t
        do {
            processID = try spawn(command, input: stdin?.fileHandleForReading.fileDescriptor,
                                   output: output.fileHandleForWriting.fileDescriptor)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return Outcome(status: nil, text: error.localizedDescription)
        }
        // The parent no longer needs the pipe ends owned by the child. Closing them here lets the
        // reader observe EOF once the process group has finished.
        try? output.fileHandleForWriting.close()
        try? stdin?.fileHandleForReading.close()
        DispatchQueue.global(qos: .userInitiated).async {
            var waitStatus: Int32 = 0
            var result: pid_t
            // wakeup-allow: the detached command's reaper waits for the child and retries only on EINTR.
            repeat { result = waitpid(processID, &waitStatus, 0) } while result == -1 && errno == EINTR
            if result == processID { exitStatus.withLock { $0 = Self.exitCode(waitStatus) } }
            exited.signal()
        }
        if let input {
            // Off this thread, so a git that never reads still meets the deadline; a hook that exits
            // first makes this a failed write, not SIGPIPE.
            DispatchQueue.global(qos: .userInitiated).async {
                _ = fcntl(shared.input.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? shared.input.write(contentsOf: input)
                try? shared.input.close()
            }
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        // concurrency-allow: runSync runs only inside output's detached task, bounded by the deadline.
        guard exited.wait(timeout: .now() + seconds) == .success else {
            _ = Darwin.kill(-processID, SIGTERM)
            // concurrency-allow: runSync runs only inside output's detached task; a short grace for SIGTERM.
            _ = exited.wait(timeout: .now() + 2)
            _ = Darwin.kill(-processID, SIGKILL)
            output.fileHandleForReading.readabilityHandler = nil
            return Outcome(status: nil, text: timedOutMessage)
        }
        // A child git started may still hold the pipe: wait a moment for the end of the output, no longer.
        // concurrency-allow: runSync runs only inside output's detached task; bounded to one second.
        _ = ended.wait(timeout: .now() + 1)
        output.fileHandleForReading.readabilityHandler = nil
        return Outcome(status: exitStatus.withLock { $0 }, text: shared.text)
    }

    /// Starts the command in its own process group so a hook or filter cannot outlive a timed-out git.
    private static func spawn(_ command: Command, input: Int32?, output: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawnattr_destroy(&attributes) }

        let inputConfigured: Bool
        if let input {
            inputConfigured = posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0
        } else {
            inputConfigured = "/dev/null".withCString {
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDONLY, 0) == 0
            }
        }
        let configured = inputConfigured
            && posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0
            && posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO) == 0
            && (command.directory.map { folder in
                folder.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) == 0 }
            } ?? true)
            && posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
        guard configured else { throw POSIXError(.EINVAL) }

        let arguments = [command.executable] + command.arguments
        let variables = command.environment.map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let status = withCStrings(arguments) { argv in
            withCStrings(variables) { envp in
                command.executable.withCString {
                    posix_spawn(&processID, $0, &actions, &attributes, argv, envp)
                }
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        return processID
    }

    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return body(pointers)
    }

    private static func exitCode(_ waitStatus: Int32) -> Int32 {
        guard waitStatus & 0x7f == 0 else { return 128 + (waitStatus & 0x7f) }
        return (waitStatus >> 8) & 0xff
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
