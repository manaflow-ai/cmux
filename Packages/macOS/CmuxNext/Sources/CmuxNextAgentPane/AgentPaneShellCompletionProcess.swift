import CmuxNextWakeups
import Darwin
import Foundation
import Synchronization

/// One completion shell: spawned in its own process group, its stdout read to EOF, reaped, and
/// killed with its group at the deadline. Answers the output, or `timedOut`.
nonisolated final class CompletionProcess: Sendable {
    private struct State {
        var output = Data()
        var closed = false
        var exited = false
        var continuation: CheckedContinuation<Data?, Never>?
        var answered = false
        /// The pipe's read end. Held until EOF, not until the shell is reaped: the shell can exit
        /// before its output ends (a background job still holds stdout, or the reaper wins the
        /// race under load), and releasing the handle then closes the pipe before EOF is read.
        var reader: FileHandle?
    }

    private let pid: pid_t
    private let state = Mutex(State())

    private init(pid: pid_t) { self.pid = pid }

    static func run(path: String, arguments: [String], environment: [String: String], folder: String, timeout: Duration)
        async throws(AgentPaneShellCompletion.Failure) -> Data {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { throw .spawnFailed(errno) }
        let pid: pid_t
        do {
            pid = try spawn(path, arguments: arguments, environment: environment, folder: folder, output: pipe[1])
        } catch {
            Darwin.close(pipe[0])
            Darwin.close(pipe[1])
            throw error
        }
        Darwin.close(pipe[1])
        let process = CompletionProcess(pid: pid)
        let deadline = DemandTimer(owner: "agent-pane.shell.complete")
        let output: Data? = await withCheckedContinuation { continuation in
            process.state.withLock { $0.continuation = continuation }
            process.start(reading: pipe[0])
            deadline.schedule(after: timeout) { process.give(up: true) }
        }
        deadline.cancel()
        guard let output else { throw .timedOut }
        return output
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
        let pid = pid
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var status: Int32 = 0
            var result: pid_t
            // wakeup-allow: a blocking wait for the completion shell's exit, retried only when a signal interrupts it.
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            finish { $0.exited = true }
        }
    }

    /// Records an end; answers with the output once the shell exited and its pipe closed.
    private func finish(_ change: (inout State) -> Void) {
        let ready = state.withLock { state -> (CheckedContinuation<Data?, Never>, Data)? in
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
        let (ready, reader) = state.withLock { state -> ((CheckedContinuation<Data?, Never>, Data?)?, FileHandle?) in
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
                              output: Int32) throws(AgentPaneShellCompletion.Failure) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw .spawnFailed(errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw .spawnFailed(errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        let configured = "/dev/null".withCString { posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDONLY, 0) } == 0
            && posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0
            && "/dev/null".withCString { posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, $0, O_WRONLY, 0) } == 0
            && folder.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) } == 0
            && posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
            && posix_spawnattr_setpgroup(&attributes, 0) == 0
        guard configured else { throw .spawnFailed(EINVAL) }
        let variables = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(arguments) { argv in
            withCStrings(variables) { envp in posix_spawn(&pid, path, &actions, &attributes, argv, envp) }
        }
        guard status == 0 else { throw .spawnFailed(status) }
        return pid
    }

    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return body(pointers)
    }
}
