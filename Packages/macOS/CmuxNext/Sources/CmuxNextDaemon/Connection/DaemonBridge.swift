public import Foundation
import Darwin
import CmuxNextCompat
import CmuxNextTrace
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceContinuation

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
    /// Where this bridge's children start and their dial lines are read; every copy shares it, and it is
    /// not part of the bridge's identity.
    private let queues = BridgeQueues()

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public static func == (lhs: DaemonBridge, rhs: DaemonBridge) -> Bool {
        lhs.executable == rhs.executable && lhs.arguments == rhs.arguments
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(executable)
        hasher.combine(arguments)
    }

    static let replyTimeoutMs: Int32 = 10_000
    static let maxReplyBytes = 1024

    /// An opened bridge: the descriptor of the connected stream and the child that carries it.
    struct Opened: Sendable {
        let fd: Int32
        let child: BridgeChild
    }

    /// A spawned bridge whose dial line is not read yet.
    private struct Spawned: Sendable {
        let opened: Opened
        /// The read end of the child's stderr (``BridgeChild`` closes it).
        let stderr: Int32
    }

    /// Spawns the bridge on its user-blocking launcher (a person waits for what comes over the link), then
    /// waits for its dial line on its dial queue; never on the caller's thread. Returns the connected stream
    /// and the child, or why it failed (the child is then killed and reaped).
    func open() async throws(DaemonError) -> Opened {
        let (bridge, launcher, dial) = (self, queues.launcher, queues.dial)
        let spawned = try await launcher.run { () throws(DaemonError) -> Spawned in try bridge.spawn(priority: launcher.priority) }
        let dropped = DaemonError.launchFailed("the bridge's dial line was never read")
        return try await withOnceContinuation(failingWith: { _ in dropped }) { (continuation: OnceContinuation<Opened, DaemonError>) in
            dial.async {
                do throws(DaemonError) {
                    try DaemonBridge.check(try Self.readLine(spawned.stderr))
                    continuation.resume(returning: spawned.opened)
                } catch {
                    spawned.opened.child.terminate()
                    Darwin.close(spawned.opened.fd)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// ``open()``'s spawn, on the launcher.
    private func spawn(priority: MayBlockPriority) throws(DaemonError) -> Spawned {
        guard executable.hasPrefix("/") else { throw .launchFailed("the bridge executable is not an absolute path") }
        var pair: [Int32] = [-1, -1]
        // SAFETY: socketpair writes two descriptors into the two-element array's storage, live for the call.
        guard unsafe socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw .launchFailed("socketpair: \(POSIXErrorText(errno))") }
        var errPipe: [Int32] = [-1, -1]
        // SAFETY: pipe writes two descriptors into the two-element array's storage, live for the call.
        guard unsafe pipe(&errPipe) == 0 else {
            Darwin.close(pair[0]); Darwin.close(pair[1])
            throw .launchFailed("pipe: \(POSIXErrorText(errno))")
        }
        let (mine, theirs, errRead, errWrite) = (pair[0], pair[1], errPipe[0], errPipe[1])
        _ = fcntl(mine, F_SETFD, FD_CLOEXEC)
        _ = fcntl(errRead, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        // SAFETY: setsockopt reads the given size, MemoryLayout<Int32>.size, from `on`, an Int32 live for the call.
        unsafe setsockopt(mine, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var actions: posix_spawn_file_actions_t?
        // SAFETY (file actions and attributes): each call gets a pointer to the local `actions` or `attributes`,
        // live for the call; _init sets each up before any other use and the defer destroys it exactly once.
        unsafe posix_spawn_file_actions_init(&actions)
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }
        unsafe posix_spawn_file_actions_adddup2(&actions, theirs, 0)
        unsafe posix_spawn_file_actions_adddup2(&actions, theirs, 1)
        unsafe posix_spawn_file_actions_adddup2(&actions, errWrite, 2)
        var attributes: posix_spawnattr_t?
        // SAFETY: as above (file actions and attributes).
        unsafe posix_spawnattr_init(&attributes)
        defer { unsafe posix_spawnattr_destroy(&attributes) }
        // Only stdin, stdout and stderr reach the child.
        // SAFETY: as above (file actions and attributes).
        unsafe posix_spawnattr_setflags(&attributes, Int16(clamping: POSIX_SPAWN_CLOEXEC_DEFAULT))
        let words = [executable] + arguments
        // SAFETY: strdup copies each Swift string into a NUL-terminated heap string; the defer frees each copy
        // exactly once, after posix_spawn has copied argv into the child.
        let argv = unsafe words.map { unsafe strdup($0) } + [nil]
        defer { unsafe argv.forEach { unsafe free($0) } }
        var pid: pid_t = 0
        // The child starts at QOS_CLASS_DEFAULT (no spawn attribute sets a class above utility); `cmux link dial`
        // puts its own threads at user-initiated (cmux-tui link/dial_cli.rs, BRIDGE_QOS).
        // SAFETY: `pid`, `actions` and `attributes` are locals live for the call; argv is the nil-terminated array
        // of live copies above; environ is the process's own nil-terminated environment, which nothing here changes.
        let spawned = unsafe blockingPosixSpawn(&pid, executable, &actions, &attributes, argv, environ, priority: priority)
        Darwin.close(theirs)
        Darwin.close(errWrite)
        guard spawned == 0 else {
            Darwin.close(mine); Darwin.close(errRead)
            throw .launchFailed("spawn \(executable): \(POSIXErrorText(spawned))")
        }
        return Spawned(opened: Opened(fd: mine, child: BridgeChild(pid: pid, stderr: errRead, reaper: queues.reap)), stderr: errRead)
    }

    /// One line from the child's stderr within the deadline.
    static func readLine(_ fd: Int32) throws(DaemonError) -> Data {
        var line: [UInt8] = []
        for _ in 0...(maxReplyBytes + 8) {
            var poller = pollfd(fd: fd, events: Int16(clamping: POLLIN), revents: 0)
            // SAFETY: poll reads and writes the one pollfd it is given, a local live for the call.
            let ready = unsafe poll(&poller, 1, replyTimeoutMs)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw .endpointBlocked("the link dial gave no answer") }
            var byte: UInt8 = 0
            // SAFETY: read writes at most 1 byte, the count given, into `byte`, a local live for the call.
            let read = unsafe Darwin.read(fd, &byte, 1)
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

extension LineTransport {
    /// A connection to `path`, or through `bridge`'s child when there is one: ``DaemonBridge/open()``
    /// spawns the child and reads its dial line off the caller's thread.
    ///
    /// - Parameter stats: Where the connection counts (``DaemonEndpoint/wireStats``); nil for none.
    /// - Parameter hangs: Watches each line's handling on the reader thread and each drain step of the
    ///   socket writer; nil watches nothing.
    /// - Parameter writerTarget: The serial queue the socket writer drains on (``SocketWriter``), nil for its own.
    static func open(path: String, bridge: DaemonBridge?, role: DaemonWireStats.Role, stats: DaemonWireStats?,
                     hangs: (any HangWatchScoping)? = nil, writerTarget: DispatchQueue? = nil,
                     trace: TraceRuntime = .shared) async throws(DaemonError) -> LineTransport {
        let opened = try await bridge?.open()
        return try LineTransport(path: path, opened: opened, role: role, stats: stats, hangs: hangs,
                                 writerTarget: writerTarget, trace: trace)
    }
}

/// The queues of one ``DaemonBridge``, made with it (one per machine session), never per connection.
final class BridgeQueues: Sendable {
    /// Spawns the bridge children, user-blocking: a person waits for what comes over the link.
    let launcher = ChildProcessLauncher(label: "com.cmuxterm.next.child-launcher.daemon-bridge", priority: .userBlocking)
    /// Waits for the dial line of each opening connection, one `poll` of up to ``DaemonBridge/replyTimeoutMs``
    /// per byte. Concurrent: one slow dial never holds another, nor a spawn (the launcher's items only spawn).
    let dial = DispatchQueue(label: "com.cmuxterm.next.daemon.bridge-dial", qos: .userInitiated, attributes: .concurrent)
    /// Reaps the killed bridge children from their process-exit sources (``ChildExitWatch``); utility, as nobody
    /// waits for a closed connection's child.
    let reap = DispatchQueue(label: "com.cmuxterm.next.daemon.bridge-reap", qos: .utility)
}

/// The bridge process of one connection: killed and reaped exactly once,
/// when the connection closes or the transport goes away.
///
/// ``terminate()`` never waits for the child, so dropping the last reference on the main thread costs a `kill`
/// and a `close`: the reap runs on the bridge's reap queue from a process-exit source, as Chromium's
/// `EnsureProcessTerminated` does (base/process/kill_mac.cc). The lock only hands the stderr descriptor to the
/// one caller that terminates; nothing is called while it is held.
final class BridgeChild: Sendable {
    let pid: pid_t
    private let errorPipe: Mutex<Int32>
    private let reaper: DispatchQueue

    /// - Parameters:
    ///   - pid: The spawned bridge child.
    ///   - stderr: The read end of its stderr, closed on ``terminate()``.
    ///   - reaper: The serial queue that reaps it (``BridgeQueues/reap``).
    init(pid: pid_t, stderr: Int32, reaper: DispatchQueue) {
        self.pid = pid
        errorPipe = Mutex(stderr)
        self.reaper = reaper
    }

    /// Kills the child, closes its stderr and starts its reap on ``reaper``; returns at once. Later calls do nothing.
    func terminate() {
        let descriptor = errorPipe.withLock { descriptor -> Int32 in
            defer { descriptor = -1 }
            return descriptor
        }
        guard descriptor >= 0 else { return }
        Darwin.kill(pid, SIGKILL)
        Darwin.close(descriptor)
        ChildExitWatch(pid: pid, queue: reaper).start { _ in }
    }

    deinit { terminate() }
}
