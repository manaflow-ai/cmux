import CmuxNextWakeups
import Darwin
public import Foundation

/// The commands shell mode runs (`!` first in the agent composer or the new tab field,
/// webviews `shell/shellRuns.ts`): each one is the user's login shell running `-l -c command`
/// in the chat's folder, in its own process group, stdin from /dev/null, stdout and stderr in
/// one pipe. The page reads the output with `shell.read` (a long poll: it answers when there is
/// output or the command ended, else after ``readWait``) and stops a command with `shell.stop`.
///
/// Bounded: at most ``maximumRunning`` commands run per pane, each keeps the last
/// ``maximumBuffer`` bytes, and finished runs past ``maximumKept`` are dropped oldest first.
/// Idle, nothing runs: no timer, only a blocked `waitpid` and a pipe read per running command.
/// Deadlines (a read's wait, Stop's escalation, the drain after exit) are one-shot DemandTimers.
public final class AgentPaneShell {
    public static let maximumRunning = 4
    public static let maximumKept = 16
    public static let maximumBuffer = 1 << 20
    public static let maximumRead = 256 << 10
    public static let readWait: Duration = .seconds(10)
    /// Output events waiting for the main actor, per running command.
    static let maximumEvents = 256
    /// Stop: SIGINT to the group, then SIGTERM and SIGKILL to what is left.
    static let stopEscalation: Duration = .seconds(2)
    /// After the shell exits, how long its pipe may still drain; a background child that keeps
    /// the pipe open does not hold the block open past it.
    static let drainAfterExit: Duration = .milliseconds(250)

    public nonisolated struct Exit: Equatable, Sendable {
        public var code: Int32?
        public var signal: Int32?
    }

    /// One `shell.read` answer: output from `after` (complete UTF-8 only while it runs), the
    /// offset to read from next, whether output before `after` was dropped, and the exit once the
    /// command ended and every byte was read.
    public nonisolated struct Chunk: Equatable, Sendable {
        public var output: String
        public var next: Int
        public var truncated: Bool
        public var exit: Exit?
    }

    public nonisolated enum Failure: Error, Equatable, Sendable {
        case tooMany
        case folderMissing
        case spawnFailed(Int32)
        case unknownRun
    }

    final class Run {
        let pid: pid_t
        var buffer = Data()
        /// The absolute offset of `buffer`'s first byte (what was dropped before it).
        var base = 0
        var exit: Exit?
        var outputClosed = false
        var stopping = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        let escalation = DemandTimer(owner: "agent-pane.shell.stop")
        let drain = DemandTimer(owner: "agent-pane.shell.drain")
        var stopReading: (() -> Void)?

        init(pid: pid_t) { self.pid = pid }

        var end: Int { base + buffer.count }
        var finished: Bool { exit != nil && outputClosed }
        func hasNews(after: Int) -> Bool { end > after || finished }

        func wake() {
            let waiting = waiters.values
            waiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
    }

    private nonisolated enum Event: Sendable {
        case output(Data)
        case closed
        case exit(Int32?)
    }

    private var runs: [String: Run] = [:]
    private var order: [String] = []
    private let shell: String
    private let environment: [String: String]
    private let home: String

    public init(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) {
        let candidate = shell ?? ""
        self.shell = candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/bin/zsh"
        var environment = environment
        // Output is shown as text: no colors or cursor movement, and no pager waiting for keys.
        environment["TERM"] = "dumb"
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        self.environment = environment
        self.home = home
    }

    /// Starts `command` in `cwd` (the home folder when nil) and returns its id.
    public func run(_ command: String, cwd: String?) throws(Failure) -> String {
        guard runs.values.filter({ $0.exit == nil }).count < Self.maximumRunning else { throw .tooMany }
        let folder = cwd ?? home
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .folderMissing
        }
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { throw .spawnFailed(errno) }
        let pid: pid_t
        do {
            pid = try spawn(command, folder: folder, output: pipe[1])
        } catch {
            Darwin.close(pipe[0])
            Darwin.close(pipe[1])
            throw error
        }
        Darwin.close(pipe[1])
        let id = UUID().uuidString
        let run = Run(pid: pid)
        runs[id] = run
        order.append(id)
        evict()
        // The main actor drains this as events come; past the cap the oldest output goes first (the
        // run keeps only its last ``maximumBuffer`` bytes anyway), never the end and exit events.
        let (events, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(Self.maximumEvents))
        let reader = FileHandle(fileDescriptor: pipe[0], closeOnDealloc: true)
        reader.readabilityHandler = { handle in
            // concurrency-allow: the readability handler runs on a background queue once data is ready.
            let data = handle.availableData
            // The stream stays open after EOF: the exit may still be on its way.
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.yield(.closed)
            } else {
                continuation.yield(.output(data))
            }
        }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            var result: pid_t
            // wakeup-allow: a blocking wait for the child's exit, retried only when a signal interrupts it.
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            // ECHILD: someone else reaped it; the exit status is unknown.
            continuation.yield(.exit(result == pid ? status : nil))
        }
        // Reading ends once the run has both its exit and its EOF, or when the drain after exit
        // gives up on a pipe a background child keeps open; either way the pipe closes.
        run.stopReading = {
            reader.readabilityHandler = nil
            continuation.finish()
        }
        Task { [weak self, weak run] in
            for await event in events {
                self?.receive(event, for: id)
                if run?.finished ?? true { break }
            }
            run?.stopReading = nil
            reader.readabilityHandler = nil
            continuation.finish()
            withExtendedLifetime(reader) {}
        }
        return id
    }

    /// Output after `after`, waiting up to ``readWait`` for some when there is none yet.
    public func read(_ id: String, after: Int) async throws(Failure) -> Chunk {
        guard let run = runs[id] else { throw .unknownRun }
        if !run.hasNews(after: after) {
            let token = UUID()
            let deadline = DemandTimer(owner: "agent-pane.shell.read")
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                run.waiters[token] = continuation
                deadline.schedule(after: Self.readWait) { @MainActor [weak run] in
                    run?.waiters.removeValue(forKey: token)?.resume()
                }
            }
            deadline.cancel()
        }
        return Self.chunk(run, after: after)
    }

    /// Interrupts the command's process group, as Ctrl-C in a terminal does; what ignores it is
    /// terminated, then killed.
    public func stop(_ id: String) {
        guard let run = runs[id], run.exit == nil, !run.stopping else { return }
        run.stopping = true
        let group = -run.pid
        kill(group, SIGINT)
        escalate(run, group: group, signals: [SIGTERM, SIGKILL])
    }

    /// Sends the next of `signals` after ``stopEscalation`` while the command still runs.
    private func escalate(_ run: Run, group: pid_t, signals: [Int32]) {
        guard let signal = signals.first else { return }
        run.escalation.schedule(after: Self.stopEscalation) { @MainActor [weak self, weak run] in
            guard let self, let run, run.exit == nil else { return }
            kill(group, signal)
            self.escalate(run, group: group, signals: Array(signals.dropFirst()))
        }
    }

    /// Ends every running command (the pane closed): hangup, as a closed terminal sends.
    public func terminateAll() {
        for run in runs.values where run.exit == nil {
            kill(-run.pid, SIGHUP)
            kill(-run.pid, SIGCONT)
        }
    }

    private func receive(_ event: Event, for id: String) {
        guard let run = runs[id] else { return }
        switch event {
        case .output(let data):
            run.buffer.append(data)
            if run.buffer.count > Self.maximumBuffer {
                let drop = run.buffer.count - Self.maximumBuffer
                run.buffer.removeFirst(drop)
                run.base += drop
            }
        case .closed:
            run.outputClosed = true
        case .exit(let status):
            run.exit = status.map(Self.exit(status:)) ?? Exit()
            run.escalation.cancel()
            if !run.outputClosed {
                run.drain.schedule(after: Self.drainAfterExit) { @MainActor [weak run] in
                    guard let run, !run.outputClosed else { return }
                    run.outputClosed = true
                    run.stopReading?()
                    run.wake()
                }
            }
        }
        run.wake()
    }

    private func evict() {
        while order.count > Self.maximumKept, let index = order.firstIndex(where: { runs[$0]?.exit != nil }) {
            runs.removeValue(forKey: order.remove(at: index))?.wake()
        }
    }

    private func spawn(_ command: String, folder: String, output: Int32) throws(Failure) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw .spawnFailed(errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw .spawnFailed(errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        let configured = "/dev/null".withCString { posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDONLY, 0) } == 0
            && posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0
            && posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO) == 0
            && folder.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) } == 0
            // Its own process group, so Stop reaches what the command started; every other
            // descriptor of the app closes in the child.
            && posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
        guard configured else { throw .spawnFailed(EINVAL) }
        let arguments = [shell, "-l", "-c", command]
        let variables = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = Self.withCStrings(arguments) { argv in
            Self.withCStrings(variables) { envp in
                posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
            }
        }
        guard status == 0 else { throw .spawnFailed(status) }
        return pid
    }

    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return body(pointers)
    }

    /// A `waitpid` status: an exit code, or the signal that ended it.
    nonisolated static func exit(status: Int32) -> Exit {
        let signal = status & 0x7F
        return signal == 0 ? Exit(code: (status >> 8) & 0xFF) : Exit(signal: signal)
    }

    static func chunk(_ run: Run, after: Int) -> Chunk {
        let start = min(max(after, run.base), run.end)
        let available = run.buffer[(run.buffer.startIndex + start - run.base)...]
        var bytes = available.prefix(maximumRead)
        let complete = run.finished && bytes.count == available.count
        if !complete { bytes = bytes.prefix(utf8Complete(bytes)) }
        let next = start + bytes.count
        return Chunk(
            output: String(decoding: bytes, as: UTF8.self),
            next: next,
            truncated: after < run.base,
            exit: complete ? run.exit : nil)
    }

    /// How many leading bytes of `bytes` end on a whole UTF-8 character.
    nonisolated static func utf8Complete(_ bytes: Data) -> Int {
        let count = bytes.count
        var back = 0
        while back < min(4, count) {
            let byte = bytes[bytes.startIndex + count - 1 - back]
            if byte & 0xC0 != 0x80 {
                let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return back + 1 >= length ? count : count - back - 1
            }
            back += 1
        }
        return count
    }
}
