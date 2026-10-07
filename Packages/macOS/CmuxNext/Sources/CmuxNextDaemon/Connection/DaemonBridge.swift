public import Foundation
import Darwin
import Synchronization

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

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    static let replyTimeoutMs: Int32 = 10_000
    static let maxReplyBytes = 1024

    /// Spawns the bridge and waits for its dial line: the descriptor of the
    /// connected stream and the child, or why it failed (the child is then
    /// killed and reaped).
    func open() throws(DaemonError) -> (fd: Int32, child: BridgeChild) {
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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        Darwin.close(theirs)
        Darwin.close(errWrite)
        guard spawned == 0 else {
            Darwin.close(mine); Darwin.close(errRead)
            throw .launchFailed("spawn \(executable): \(String(cString: strerror(spawned)))")
        }
        let child = BridgeChild(pid: pid, stderr: errRead)
        do {
            try DaemonBridge.check(try Self.readLine(errRead))
        } catch {
            child.terminate()
            Darwin.close(mine)
            throw error
        }
        return (mine, child)
    }

    /// One line from the child's stderr within the deadline.
    static func readLine(_ fd: Int32) throws(DaemonError) -> Data {
        var line: [UInt8] = []
        for _ in 0...(maxReplyBytes + 8) {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, replyTimeoutMs)
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

    /// The dial line: `"ok": true` passes; a refusal names its `error_code`.
    static func check(_ reply: Data) throws(DaemonError) {
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        guard let object else { throw .endpointBlocked("the link dial's answer is not JSON") }
        if object["ok"] as? Bool == true { return }
        throw .endpointBlocked("the link refused the dial: \(object["error_code"] as? String ?? "refused")")
    }
}

/// The bridge process of one connection: killed and reaped exactly once,
/// when the connection closes or the transport goes away.
final class BridgeChild: Sendable {
    let pid: pid_t
    private let state: Mutex<Int32>

    init(pid: pid_t, stderr: Int32) {
        self.pid = pid
        state = Mutex(stderr)
    }

    func terminate() {
        state.withLock { stderr in
            guard stderr >= 0 else { return }
            Darwin.kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            Darwin.close(stderr)
            stderr = -1
        }
    }

    deinit { terminate() }
}
