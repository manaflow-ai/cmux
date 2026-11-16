public import Foundation
import Darwin
import CmuxNextCompat

/// A daemon connection through a child process instead of a socket
/// (plans/cmux-next/server-reach.md 7 step 1): the app's own bundled `cmux`
/// with a fixed argv (`link dial --host … --service owner_session …`) carries
/// the stream on its stdin and stdout, and reports the dial on stderr as one
/// JSON line first (`{"ok":true,…}` or `{"ok":false,"error_code":…}`). The
/// app never talks to the link's socket itself, so the link's caller rule
/// (same code signature) stays unchanged in every build.
public struct DaemonBridge: Hashable, Sendable {
    /// An absolute path inside the app bundle (never looked up on PATH).
    public var executable: String
    public var arguments: [String]
    /// Variables set for the child on top of the app's environment (a carrier dial's platform origin and token).
    public var environment: [String: String]
    /// How long the child may take to write its dial line (a carrier dial waits out a cold machine's resume).
    public var replyTimeoutMs: Int32

    public init(executable: String, arguments: [String], environment: [String: String] = [:], replyTimeoutMs: Int32 = 10_000) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.replyTimeoutMs = replyTimeoutMs
    }

    static let maxReplyBytes = 1024

    /// Spawns the bridge and waits for its dial line: the descriptor of the
    /// connected stream and the child, or why it failed (the child is then
    /// killed and reaped). `spawned` gets, once the child runs, a kill for it while it dials (an
    /// owner ending it early: the wait then fails as a dial that ended without an answer).
    /// `progress` gets the text of each progress line the child writes before its dial line
    /// (`{"progress":{"text":…}}`, a carrier dial run with `CMUX_CARRIER_PROGRESS=1`), on this thread.
    func open(spawned: (_ kill: @escaping @Sendable () -> Void) -> Void = { _ in },
              progress: (String) -> Void = { _ in }) throws(DaemonError) -> (fd: Int32, child: BridgeChild) {
        guard executable.hasPrefix("/") else { throw .launchFailed("the bridge executable is not an absolute path") }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw .launchFailed("socketpair: \(String(cString: strerror(errno)))") }
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&errPipe) == 0 else {
            Darwin.close(pair[0]); Darwin.close(pair[1])
            throw .launchFailed("pipe: \(String(cString: strerror(errno)))")
        }
        let (mine, theirs, errRead, errWrite) = (pair[0], pair[1], errPipe[0], errPipe[1])
        _ = fcntl(mine, F_SETFD, FD_CLOEXEC)
        _ = fcntl(errRead, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(mine, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, theirs, 0)
        posix_spawn_file_actions_adddup2(&actions, theirs, 1)
        posix_spawn_file_actions_adddup2(&actions, errWrite, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only stdin, stdout and stderr reach the child.
        posix_spawnattr_setflags(&attributes, Int16(clamping: POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let envp = environment.isEmpty ? nil
            : ProcessInfo.processInfo.environment.merging(environment) { $1 }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in envp ?? [] { free(pointer) } }
        let status = if let envp { blockingPosixSpawn(&pid, executable, &actions, &attributes, argv, envp) }
            else { blockingPosixSpawn(&pid, executable, &actions, &attributes, argv, environ) }
        Darwin.close(theirs)
        Darwin.close(errWrite)
        guard status == 0 else {
            Darwin.close(mine); Darwin.close(errRead)
            throw .launchFailed("spawn \(executable): \(String(cString: strerror(status)))")
        }
        let child = BridgeChild(pid: pid, stderr: errRead)
        spawned { [weak child] in child?.kill() }
        do {
            // The dial line's deadline holds across the progress lines before it.
            let deadline = ContinuousClock.now + .milliseconds(replyTimeoutMs)
            var line = try Self.readLine(errRead, timeoutMs: replyTimeoutMs)
            while let text = Self.progressText(line) {
                progress(text)
                let left = (deadline - ContinuousClock.now).components
                let ms = left.seconds * 1000 + left.attoseconds / 1_000_000_000_000_000
                line = try Self.readLine(errRead, timeoutMs: Int32(clamping: max(ms, 1)))
            }
            try DaemonBridge.check(line)
        } catch {
            child.terminate()
            Darwin.close(mine)
            throw error
        }
        // The dial line is the last stderr line this reads; the child may write more for as long as it lives.
        child.drainStderr()
        return (mine, child)
    }

    /// One line from the child's stderr within the deadline.
    static func readLine(_ fd: Int32, timeoutMs: Int32) throws(DaemonError) -> Data {
        var line: [UInt8] = []
        for _ in 0...(maxReplyBytes + 8) {
            var poller = pollfd(fd: fd, events: Int16(clamping: POLLIN), revents: 0)
            let ready = poll(&poller, 1, timeoutMs)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw .endpointBlocked("the link dial gave no answer") }
            var byte: UInt8 = 0
            let read = Darwin.read(fd, &byte, 1)
            if read < 0, errno == EINTR { continue }
            guard read == 1 else { throw .endpointBlocked("the link dial ended without an answer") }
            if byte == UInt8(ascii: "\n") { return Data(line) }
            guard line.count < maxReplyBytes else { break }
            line.append(byte)
        }
        throw .endpointBlocked("the link dial's answer is too long")
    }

    /// The person-readable text of a progress line (`{"progress":{"text":…}}`), cut to
    /// `maxDetailCharacters`; nil for any other line (the dial line).
    static func progressText(_ line: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        guard let progress = object?["progress"] as? [String: Any], let text = progress["text"] as? String, !text.isEmpty
        else { return nil }
        return String(text.prefix(maxDetailCharacters))
    }

    /// The dial line: `"ok": true` passes; a refusal names its `error_code` (the stage) and its
    /// `error_detail`, cut to `maxDetailCharacters`, so the session's end reason says why.
    static func check(_ reply: Data) throws(DaemonError) {
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        guard let object else { throw .endpointBlocked("the link dial's answer is not JSON") }
        if object["ok"] as? Bool == true { return }
        var refusal = object["error_code"] as? String ?? "refused"
        if let detail = object["error_detail"] as? String, !detail.isEmpty {
            refusal += ": \(detail.prefix(maxDetailCharacters))"
        }
        throw .endpointBlocked("the link refused the dial: \(refusal)")
    }

    /// The longest refusal detail kept from the dial line.
    static let maxDetailCharacters = 300
}

/// The bridge process of one connection: killed and reaped exactly once,
/// when the connection closes or the transport goes away.
final class BridgeChild: Sendable {
    private struct State {
        var reaped = false
        /// The read end of the child's stderr while this closes it: -1 once closed, or once `drain` owns it.
        var stderr: Int32
        /// Reads and drops the child's stderr after its dial line; its cancel handler closes the descriptor.
        var drain: (any DispatchSourceRead)?
    }

    let pid: pid_t
    private let state: Mutex<State>
    private static let drainQueue = DispatchQueue(label: "com.cmuxterm.next.bridge-stderr", qos: .utility)

    init(pid: pid_t, stderr: Int32) {
        self.pid = pid
        state = Mutex(State(stderr: stderr))
    }

    /// Signals the child without reaping it (its owner still does, in ``terminate()``); nothing once reaped.
    func kill() {
        state.withLock { state in
            guard !state.reaped else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }

    /// Reads and drops what the child writes to stderr from now on, for its whole life. Nobody
    /// reads that pipe after the dial line, so without this a child that keeps writing fills it
    /// (64 KB) and stops in `write` for good. The watch ends, and the read end closes, at end of
    /// file (the child exited) or in ``terminate()``. Nothing once reaped.
    func drainStderr() {
        state.withLock { state in
            guard !state.reaped, state.stderr >= 0 else { return }
            let fd = state.stderr
            // A read that finds nothing ready returns at once: the watch's queue never waits in it.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.drainQueue)
            source.setEventHandler { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 || (count < 0 && (errno == EINTR || errno == EAGAIN)) { return }
                self?.endDrain()
            }
            // The descriptor closes only here, on the watch's queue after its last read: never under a read.
            source.setCancelHandler { Darwin.close(fd) }
            source.activate()
            state.stderr = -1
            state.drain = source
        }
    }

    /// Ends the stderr watch (end of file, or a read that failed); its cancel handler closes the read end.
    private func endDrain() {
        state.withLock { state in
            state.drain?.cancel()
            state.drain = nil
        }
    }

    func terminate() {
        state.withLock { state in
            guard !state.reaped else { return }
            state.reaped = true
            Darwin.kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            if state.stderr >= 0 {
                Darwin.close(state.stderr)
                state.stderr = -1
            }
            state.drain?.cancel()
            state.drain = nil
        }
    }

    deinit { terminate() }
}
