import CmuxNextCompat
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
    static func run(_ arguments: [String], input: Data? = nil, timeout: Duration) async -> String? {
        let outcome = await output(arguments, input: input, timeout: timeout)
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

    static func output(_ arguments: [String], input: Data? = nil, timeout: Duration) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            runSync(arguments, input: input, timeout: timeout)
        }.value
    }

    /// State the pipe's reader and the input's writer share with the run. Unchecked for the input
    /// handle, which only the writer touches.
    private final class Shared: @unchecked Sendable {
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

    private static func runSync(_ arguments: [String], input: Data?, timeout: Duration) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = environment()
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
        return Outcome(status: process.terminationStatus, text: shared.text)
    }

    /// The user's own git settings (HOME) and none of the App's environment; never a terminal
    /// prompt for credentials.
    static func environment() -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { environment["HOME"] = home }
        return environment
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
