import CmuxNextWakeups
import Darwin
import Foundation
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// One completion shell: spawned in its own process group, its stdout read to EOF, reaped, and
/// killed with its group at the deadline (a ``Deadline`` race, off main). Answers the output, or `timedOut`.
nonisolated final class CompletionProcess: Sendable {
    private struct State {
        var output = Data()
        var closed = false
        var exited = false
        var continuation: OnceContinuation<Data?, OnceContinuationError>?
        var answered = false
        /// The pipe's read end. Held until EOF, not until the shell is reaped: the shell can exit
        /// before its output ends (a background job still holds stdout, or the reaper wins the
        /// race under load), and releasing the handle then closes the pipe before EOF is read.
        var reader: FileHandle?
    }

    private let pid: pid_t
    private let state = Mutex(State())

    private init(pid: pid_t) { self.pid = pid }

    /// Spawns the shell on `launcher` (never on the caller's thread, the main actor) and answers its output.
    static func run(path: String, arguments: [String], environment: [String: String], folder: String, timeout: Duration,
                    launcher: ChildProcessLauncher) async throws(AgentPaneShellCompletion.Failure) -> Data {
        var pipe: [Int32] = [-1, -1]
        // SAFETY: pipe writes its two descriptors into the array's own storage (two Int32), lent for the call.
        guard unsafe Darwin.pipe(&pipe) == 0 else { throw .spawnFailed(errno) }
        let pid: pid_t
        let writeEnd = pipe[1]
        do {
            pid = try await launcher.run { () throws(AgentPaneShellCompletion.Failure) -> pid_t in
                try Self.spawn(path, arguments: arguments, environment: environment, folder: folder, output: writeEnd,
                               priority: launcher.priority)
            }
        } catch {
            Darwin.close(pipe[0])
            Darwin.close(pipe[1])
            throw error
        }
        Darwin.close(pipe[1])
        let process = CompletionProcess(pid: pid)
        let reading = pipe[0]
        let output: Data?
        do {
            output = try await Deadline(timeout).run("agent-pane.shell.complete", onTimeout: { process.give(up: true) }) {
                await process.output(reading: reading)
            }
        } catch {
            // The limit or the caller's cancellation won: the group is killed and the pipe let go.
            process.give(up: true)
            throw .timedOut
        }
        guard let output else { throw .timedOut }
        return output
    }

    /// Reads the pipe until the shell exited and its output ended, or what was read when it was given up for its
    /// length; nil when it timed out. Abandoned (the process dropped its continuation) answers as a timeout.
    private func output(reading descriptor: Int32) async -> Data? {
        try? await withOnceContinuation { (continuation: OnceContinuation<Data?, OnceContinuationError>) in
            state.withLock { $0.continuation = continuation }
            start(reading: descriptor)
        }
    }

    private func start(reading descriptor: Int32) {
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        state.withLock { $0.reader = reader }
        reader.readabilityHandler = { [self] handle in
            // concurrency-allow: the readability handler runs on a background queue once data is ready.
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finish { $0.closed = true; $0.reader = nil }
            } else {
                let full = state.withLock { state in
                    state.output.append(data)
                    return state.output.count > AgentPaneShellCompletion.maximumOutput
                }
                if full { give(up: false) }
            }
        }
        // Reaped from an exit source on its own queue, so no thread waits in `waitpid` while it runs; the Tab waits.
        ChildExitWatch(pid: pid, queue: DispatchQueue(label: "cmux.next.agent-pane.shell-complete-reap.\(pid)", qos: .userInitiated))
            .start { [self] _ in finish { $0.exited = true } }
    }

    /// Records an end; answers with the output once the shell exited and its pipe closed.
    private func finish(_ change: (inout State) -> Void) {
        let ready = state.withLock { state -> (OnceContinuation<Data?, OnceContinuationError>, Data)? in
            change(&state)
            guard state.closed, state.exited, !state.answered, let continuation = state.continuation else { return nil }
            state.answered = true
            return (continuation, state.output)
        }
        ready?.0.resume(returning: ready?.1)
    }

    /// The deadline passed (`timedOut`) or the output is too long (what was read so far): kills the group.
    private func give(up timedOut: Bool) {
        kill(-pid, SIGKILL)
        let (ready, reader) = state.withLock { state -> ((OnceContinuation<Data?, OnceContinuationError>, Data?)?, FileHandle?) in
            // The answer is final: stop reading, so a holder outside the killed group cannot keep the pipe open.
            let reader = state.reader
            state.reader = nil
            guard !state.answered, let continuation = state.continuation else { return (nil, reader) }
            state.answered = true
            return ((continuation, timedOut ? nil : state.output), reader)
        }
        reader?.readabilityHandler = nil
        ready?.0.resume(returning: ready?.1)
    }

    private static func spawn(_ path: String, arguments: [String], environment: [String: String], folder: String,
                              output: Int32, priority: MayBlockPriority) throws(AgentPaneShellCompletion.Failure) -> pid_t {
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
              unsafe posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              unsafe posix_spawn_file_actions_addchdir_np(&actions, folder) == 0,
              unsafe posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              unsafe posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw .spawnFailed(EINVAL) }
        let variables = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        // SAFETY: argv and envp are NULL-terminated lists that withCStringList lends for its closure; posix_spawn
        // copies them, writes the child's pid into `pid`, a local, and reads `actions` and `attributes` (above).
        let status = unsafe withCStringList(arguments) { argv in
            unsafe withCStringList(variables) { envp in
                unsafe blockingPosixSpawn(&pid, path, &actions, &attributes, argv, envp, priority: priority)
            }
        }
        guard let status = status.flatMap({ $0 }) else { throw .spawnFailed(ENOMEM) }
        guard status == 0 else { throw .spawnFailed(status) }
        return pid
    }
}
