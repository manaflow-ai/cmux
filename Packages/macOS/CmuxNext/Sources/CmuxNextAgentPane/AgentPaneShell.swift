import CmuxNextCompat
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
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
/// Idle, nothing runs: no timer, only a process-exit source (``ChildExitWatch``) and a pipe read per running command.
/// Deadlines (a read's wait, Stop's escalation, the drain after exit) are `visible` MainDeadlines on the app's one
/// placer: the page waits on each, so none is ever held for a hidden pane (p06-scheduler.md rule 6).
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
    /// Shell mode's Tab (`shell.complete`); tests replace it.
    var completion = AgentPaneShellCompletion()

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
        var waiters: [UUID: OnceContinuation<Void, OnceContinuationError>] = [:]
        let escalation: MainDeadline
        let drain: MainDeadline
        var stopReading: (() -> Void)?

        init(pid: pid_t, deadlines: MainDeadlineScheduler) {
            self.pid = pid
            escalation = MainDeadline(owner: "agent-pane.shell.stop", workClass: .visible, scheduler: deadlines)
            drain = MainDeadline(owner: "agent-pane.shell.drain", workClass: .visible, scheduler: deadlines)
        }

        var end: Int { base + buffer.count }
        var finished: Bool { exit != nil && outputClosed }
        func hasNews(after: Int) -> Bool { end > after || finished }

        func wake() {
            let waiting = waiters.values
            waiters.removeAll()
            for waiter in waiting { waiter.resume(returning: ()) }
        }
    }

    private nonisolated enum Event: Sendable {
        case output(Data)
        case closed
        case exit(Int32?)
    }

    private var runs: [String: Run] = [:]
    /// Runs whose spawn is in flight (``run(_:cwd:)`` awaits it): they count against ``maximumRunning``.
    private var spawning = 0
    /// ``terminateAll()`` ran (the pane closed): a run whose spawn returns after it is hung up at once.
    private var terminated = false
    private var order: [String] = []
    private let shell: String
    private let environment: [String: String]
    private let home: String
    /// The app's one deadline placer (`AppServices.mainDeadlines`).
    private let deadlines: MainDeadlineScheduler
    /// Spawns this pane's commands, in order, off the main actor: a command a person started shows soon.
    let launcher = ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.agent-shell", priority: .userVisible)

    /// - Parameters:
    ///   - shell: The login shell; one that is not an executable absolute path runs `/bin/zsh`.
    ///   - environment: The commands' environment.
    ///   - home: The folder of a command that names none.
    ///   - deadlines: The app's one deadline placer (`AppServices.mainDeadlines`), for the reads' waits, Stop's
    ///     escalation and the drain after exit.
    public init(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        deadlines: MainDeadlineScheduler
    ) {
        self.deadlines = deadlines
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

    /// Starts `command` in `cwd` (the home folder when nil) and returns its id. The spawn runs on
    /// ``launcher``, never on the main actor.
    public func run(_ command: String, cwd: String?) async throws(Failure) -> String {
        guard runs.values.filter({ $0.exit == nil }).count + spawning < Self.maximumRunning else { throw .tooMany }
        let folder = cwd ?? home
        guard AcpmuxPathPolicy.isDirectory(folder) else {
            throw .folderMissing
        }
        var pipe: [Int32] = [-1, -1]
        // SAFETY: pipe writes its two descriptors into the array's own storage (two Int32), lent for the call.
        guard unsafe Darwin.pipe(&pipe) == 0 else { throw .spawnFailed(errno) }
        let pid: pid_t
        let (shell, variables, output) = (self.shell, environment.map { "\($0.key)=\($0.value)" }, pipe[1])
        let launcher = self.launcher
        // The slot is held across the spawn's await: a second run meanwhile counts it.
        spawning += 1
        defer { spawning -= 1 }
        do {
            pid = try await launcher.run { () throws(Failure) -> pid_t in
                try Self.spawn(command, shell: shell, variables: variables, folder: folder, output: output,
                               priority: launcher.priority)
            }
        } catch {
            Darwin.close(pipe[0])
            Darwin.close(pipe[1])
            throw error
        }
        Darwin.close(pipe[1])
        let id = UUID().uuidString
        let run = Run(pid: pid, deadlines: deadlines)
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
        // Reaped from an exit source on its own queue, so no thread waits in `waitpid` while the command runs.
        // A nil status (ECHILD): someone else reaped it; the exit status is unknown.
        ChildExitWatch(pid: pid, queue: DispatchQueue(label: "cmux.next.agent-pane.shell-reap.\(pid)", qos: .utility))
            .start { status in continuation.yield(.exit(status)) }
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
        // The pane closed while the spawn was in flight: hang the command up as terminateAll() did the others.
        if terminated { hangUp(run) }
        return id
    }

    /// Output after `after`, waiting up to ``readWait`` for some when there is none yet.
    public func read(_ id: String, after: Int) async throws(Failure) -> Chunk {
        guard let run = runs[id] else { throw .unknownRun }
        if !run.hasNews(after: after) {
            let token = UUID()
            let deadline = MainDeadline(owner: "agent-pane.shell.read", workClass: .visible, scheduler: deadlines)
            // Abandoned (the run dropped its waiters) ends the wait as the deadline does: the chunk says what came.
            try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
                run.waiters[token] = continuation
                deadline.schedule(after: Self.readWait) { [weak run] in
                    run?.waiters.removeValue(forKey: token)?.resume(returning: ())
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
        run.escalation.schedule(after: Self.stopEscalation) { [weak self, weak run] in
            guard let self, let run, run.exit == nil else { return }
            kill(group, signal)
            self.escalate(run, group: group, signals: Array(signals.dropFirst()))
        }
    }

    /// A command ran in this pane (running, starting, or its output kept): closing the pane ends it or drops
    /// its output.
    public var hasRuns: Bool { !runs.isEmpty || spawning > 0 }

    /// Ends every running command (the pane closed): hangup, as a closed terminal sends. A command whose
    /// spawn is still in flight is hung up when it returns.
    public func terminateAll() {
        terminated = true
        for run in runs.values where run.exit == nil { hangUp(run) }
    }

    private func hangUp(_ run: Run) {
        kill(-run.pid, SIGHUP)
        kill(-run.pid, SIGCONT)
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
                run.drain.schedule(after: Self.drainAfterExit) { [weak run] in
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

    /// Spawns `shell -l -c command` in `folder` at `priority`; blocking, so ``run(_:cwd:)`` calls it on a launcher.
    private nonisolated static func spawn(_ command: String, shell: String, variables: [String], folder: String,
                                          output: Int32, priority: MayBlockPriority) throws(Failure) -> pid_t {
        // SAFETY (every posix_spawn_* call below): each takes the address of `actions` or `attributes`, locals
        // initialized here and destroyed once by the defers, and copies the C strings it is lent (the NUL-terminated
        // copies made for the call) before it returns.
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard unsafe posix_spawn_file_actions_init(&actions) == 0 else { throw .spawnFailed(errno) }
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }
        guard unsafe posix_spawnattr_init(&attributes) == 0 else { throw .spawnFailed(errno) }
        defer { unsafe posix_spawnattr_destroy(&attributes) }
        guard unsafe posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              unsafe posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0,
              unsafe posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO) == 0,
              unsafe posix_spawn_file_actions_addchdir_np(&actions, folder) == 0,
              // Its own process group, so Stop reaches what the command started; every other
              // descriptor of the app closes in the child.
              unsafe posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              unsafe posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw .spawnFailed(EINVAL) }
        let arguments = [shell, "-l", "-c", command]
        var pid: pid_t = 0
        // SAFETY: argv and envp are NULL-terminated lists that withCStringList lends for its closure; posix_spawn
        // copies them, writes the child's pid into `pid`, a local, and reads `actions` and `attributes` (above).
        let status = unsafe withCStringList(arguments) { argv in
            unsafe withCStringList(variables) { envp in
                unsafe blockingPosixSpawn(&pid, shell, &actions, &attributes, argv, envp, priority: priority)
            }
        }
        guard let status = status.flatMap({ $0 }) else { throw .spawnFailed(ENOMEM) }
        guard status == 0 else { throw .spawnFailed(status) }
        return pid
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
