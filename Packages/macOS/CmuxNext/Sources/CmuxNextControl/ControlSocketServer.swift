public import Foundation
import CmuxNextSettings
import Darwin
import CmuxNextWakeups
import Synchronization

/// The app control socket: a Unix stream socket speaking the old app's
/// line protocol (one v2 JSON request per line, one JSON response line per
/// request, plus the v1 `ping` and `auth <password>` lines the CLI sends).
///
/// All socket IO runs on private dispatch queues and never on the main
/// thread. Each connection handles its requests in order on one task;
/// reads answer from the published snapshot and mutations go through the
/// router's bounded main-actor work queue. Per-connection inbound and
/// outbound buffers are capped, so a slow client only stalls itself.
///
/// Authorization follows the old `SocketControlMode` model: `cmuxOnly`
/// admits processes started inside this cmux (descended from this app or
/// from a process running one of `trustedExecutables`, the bundled cmux
/// binary that hosts every terminal), `automation` admits the same
/// user, `password` also requires `auth <password>` / `auth.login`, and
/// `allowAll` admits anyone. The socket file is 0600 except for `allowAll`.
public final class ControlSocketServer: Sendable {
    public struct Configuration: Sendable {
        public var path: String
        public var accessMode: ControlAccessMode
        /// Verifies a password for `.password` mode. Nil rejects every login.
        public var passwordVerifier: (@Sendable (String) -> Bool)?
        /// Process whose descendants `.cmuxOnly` admits (default: this app).
        public var trustedAncestor: pid_t
        /// Executables whose processes' descendants `.cmuxOnly` also admits:
        /// the bundled `bin/cmux`, which runs the daemon and the terminal
        /// hosts that survive app and daemon restarts (real paths).
        public var trustedExecutables: Set<String>
        /// Longest accepted request line.
        public var maxLineBytes: Int
        /// Parsed request lines that may wait per connection before reading pauses.
        public var maxQueuedLinesPerConnection: Int
        /// Unsent response bytes per connection before the client is dropped.
        public var maxOutboxBytesPerConnection: Int

        public init(
            path: String,
            accessMode: ControlAccessMode,
            passwordVerifier: (@Sendable (String) -> Bool)? = nil,
            trustedAncestor: pid_t = getpid(),
            trustedExecutables: Set<String> = [],
            maxLineBytes: Int = 4 << 20,
            maxQueuedLinesPerConnection: Int = 64,
            maxOutboxBytesPerConnection: Int = 8 << 20
        ) {
            self.path = path
            self.accessMode = accessMode
            self.passwordVerifier = passwordVerifier
            self.trustedAncestor = trustedAncestor
            self.trustedExecutables = trustedExecutables
            self.maxLineBytes = maxLineBytes
            self.maxQueuedLinesPerConnection = maxQueuedLinesPerConnection
            self.maxOutboxBytesPerConnection = maxOutboxBytesPerConnection
        }
    }

    public enum StartError: Error, Sendable, Equatable, CustomStringConvertible {
        case disabled
        case pathTooLong(String)
        /// Another live process owns the path. The server never steals it.
        case addressInUse(String)
        /// Something other than a socket, or another user's socket, is there.
        case pathOccupied(String)
        case system(call: String, errno: Int32)

        public var description: String {
            switch self {
            case .disabled: "the control socket is disabled (access mode off)"
            case .pathTooLong(let path): "socket path is too long: \(path)"
            case .addressInUse(let path): "another process is listening on \(path)"
            case .pathOccupied(let path): "\(path) exists and is not a stale socket owned by this user"
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    public let configuration: Configuration
    public let router: ControlRouter
    private let acceptQueue = DispatchQueue(label: "com.cmuxterm.next.control.accept")
    private let state = Mutex(ServerState())

    struct ServerState {
        var listener: (any DispatchSourceRead)?
        var socketIdentity: (dev: dev_t, ino: ino_t)?
        var connections: [ControlConnectionID: ControlConnection] = [:]
        var nextConnection: UInt64 = 1
        /// Spacing of accept retries while descriptors are exhausted.
        var acceptBackoff = Backoff(initial: .milliseconds(50), maximum: .seconds(2))
        var acceptSuspended = false
    }

    /// `accept(2)`, replaceable in tests.
    typealias AcceptCall = @Sendable (Int32) -> Int32
    /// `bind(2)`; tests wrap it to act while the socket file is created.
    typealias BindCall = @Sendable (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32
    private let acceptCall: AcceptCall
    private let bindCall: BindCall
    private let acceptRetry = DemandTimer(owner: "ControlSocketServer.acceptRetry")

    public convenience init(configuration: Configuration, router: ControlRouter) {
        self.init(configuration: configuration, router: router, accept: { accept($0, nil, nil) })
    }

    init(configuration: Configuration, router: ControlRouter, accept: @escaping AcceptCall,
         bind: @escaping BindCall = { Darwin.bind($0, $1, $2) }) {
        self.configuration = configuration
        self.router = router
        self.acceptCall = accept
        self.bindCall = bind
    }

    deinit {
        stop()
    }

    public var isRunning: Bool { state.withLock { $0.listener != nil } }

    /// Open client connections.
    public var connectionCount: Int { state.withLock { $0.connections.count } }

    /// Binds and starts accepting. Throws instead of replacing a live socket.
    public func start() throws {
        guard configuration.accessMode != .off else { throw StartError.disabled }
        guard !isRunning else { return }
        let path = configuration.path
        try Self.reclaimStalePath(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartError.system(call: "socket", errno: errno) }
        var shouldClose = true
        defer { if shouldClose { close(descriptor) } }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < capacity else { throw StartError.pathTooLong(path) }
        try bindSocket(descriptor, at: path, mode: configuration.accessMode.filePermissions, capacity: capacity)
        guard listen(descriptor, 64) == 0 else {
            let code = errno
            unlink(path)
            throw StartError.system(call: "listen", errno: code)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        var info = stat()
        let identity = lstat(path, &info) == 0 ? (info.st_dev, info.st_ino) : nil
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(listener: descriptor) }
        source.setCancelHandler { close(descriptor) }
        shouldClose = false
        state.withLock {
            $0.listener = source
            $0.socketIdentity = identity.map { (dev: $0.0, ino: $0.1) }
        }
        router.setTransportInfo(socketPath: path, accessMode: configuration.accessMode.rawValue)
        source.resume()
    }

    /// Creates the socket file at `path` with `mode`, without touching the
    /// process-wide umask (another thread's files would get that mask).
    /// Binds inside a private 0700 directory next to `path`, sets the mode
    /// there, then renames the socket into place (`RENAME_EXCL`: a socket
    /// another process created meanwhile is never replaced). When the
    /// private path does not fit `sun_path`, binds at `path` and sets the
    /// mode at once: the file briefly has the umask's mode, which with the
    /// usual umask grants no one else the write access a connect needs.
    private func bindSocket(_ descriptor: Int32, at path: String, mode: mode_t, capacity: Int) throws {
        let parent = (path as NSString).deletingLastPathComponent
        var template = Array((parent.isEmpty ? "." : parent).utf8CString.dropLast()) + Array("/.cmuxsock.XXXXXX".utf8CString)
        let staging: String? = template.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.flatMap { mkdtemp($0) }.map { String(cString: $0) }
        }
        if let staging {
            defer { rmdir(staging) }
            let staged = staging + "/s"
            if staged.utf8.count < capacity {
                try bindAddress(descriptor, staged)
                guard chmod(staged, mode) == 0 else {
                    let code = errno
                    unlink(staged)
                    throw StartError.system(call: "chmod", errno: code)
                }
                guard renamex_np(staged, path, UInt32(RENAME_EXCL)) == 0 else {
                    let code = errno
                    unlink(staged)
                    throw code == EEXIST ? StartError.addressInUse(path) : StartError.system(call: "rename", errno: code)
                }
                return try verifyMode(path, mode)
            }
        }
        try bindAddress(descriptor, path)
        chmod(path, mode)
        try verifyMode(path, mode)
    }

    private func bindAddress(_ descriptor: Int32, _ path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bindCall(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            throw code == EADDRINUSE ? StartError.addressInUse(path) : StartError.system(call: "bind", errno: code)
        }
    }

    /// The socket at `path` must have exactly `mode`; otherwise it is removed.
    private func verifyMode(_ path: String, _ mode: mode_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw StartError.system(call: "lstat", errno: errno) }
        guard info.st_mode & 0o777 == mode else {
            unlink(path)
            throw StartError.system(call: "chmod", errno: EPERM)
        }
    }

    /// Stops accepting, closes every connection, and removes the socket file
    /// if it is still the one this server created.
    public func stop() {
        acceptRetry.cancel()
        let (listener, identity, connections) = state.withLock { state in
            let result = (state.listener, state.socketIdentity, Array(state.connections.values))
            // A suspended source never runs its cancel handler (the listener fd would leak).
            if state.acceptSuspended { state.listener?.resume() }
            state.acceptSuspended = false
            state.listener = nil
            state.socketIdentity = nil
            state.connections = [:]
            return result
        }
        guard listener != nil || !connections.isEmpty else { return }
        listener?.cancel()
        connections.forEach { $0.close() }
        var info = stat()
        if let identity, lstat(configuration.path, &info) == 0, info.st_dev == identity.dev, info.st_ino == identity.ino {
            unlink(configuration.path)
        }
    }

    /// Removes a leftover socket from a crashed run. Unlinks only when a
    /// connect is refused (nothing listens). Refuses when a process accepts
    /// on it or the probe is inconclusive (a busy listener, a permission
    /// error), when it is not a socket, or when another user owns it.
    static func reclaimStalePath(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw StartError.pathOccupied(path) }
        guard probe(path) == .refused else { throw StartError.addressInUse(path) }
        unlink(path)
    }

    enum ProbeResult: Equatable {
        case accepted
        /// `ECONNREFUSED`: no process listens; the file is stale.
        case refused
        case inconclusive(Int32)
    }

    static func probe(_ path: String) -> ProbeResult {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .inconclusive(errno) }
        defer { close(descriptor) }
        // Never block the caller (the App starts the server on the main
        // actor): a listener with a full backlog answers EAGAIN, not a wait.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return .inconclusive(ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .accepted }
        let code = errno
        // EAGAIN (full backlog) is inconclusive: a live listener is busy.
        return code == ECONNREFUSED ? .refused : .inconclusive(code)
    }

    // MARK: - Accepting

    private func pauseAccepting() {
        let delay: Duration? = state.withLock { state in
            guard let listener = state.listener, !state.acceptSuspended else { return nil }
            state.acceptSuspended = true
            listener.suspend()
            return state.acceptBackoff.next()
        }
        guard let delay else { return }
        WakeupLedger.shared.record("ControlSocketServer.accept", reason: "descriptor exhaustion")
        acceptRetry.schedule(after: delay) { [weak self] in self?.resumeAccepting() }
    }

    private func resumeAccepting() {
        state.withLock { state in
            guard state.acceptSuspended else { return }
            state.acceptSuspended = false
            state.listener?.resume()
        }
    }

    /// Accepts every waiting connection. The listener is non-blocking and
    /// its read source level-triggered, so each exit path either drained
    /// the backlog (EAGAIN: wait for readiness) or stops the source: a
    /// failure that leaves the connection queued (EMFILE, ENFILE, ENOBUFS,
    /// ENOMEM) suspends it and resumes after a capped backoff; retrying at
    /// once would spin at 100% CPU until descriptors free up.
    private func acceptPending(listener: Int32) {
        // wakeup-allow: drains the accept backlog; EAGAIN returns (readiness), other failures pause with Backoff
        while true {
            let client = acceptCall(listener)
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED, EPROTO:
                    continue // this connection is gone; try the next one
                case EAGAIN:
                    return // backlog drained; the source fires on the next one
                default:
                    pauseAccepting()
                    return
                }
            }
            state.withLock { $0.acceptBackoff.reset() }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            let peer = Self.peer(of: client)
            let authorizer = ControlAuthorizer(configuration: configuration, peer: peer)
            let limits = ControlConnection.Limits(
                maxLineBytes: configuration.maxLineBytes,
                maxQueuedLines: configuration.maxQueuedLinesPerConnection,
                maxOutboxBytes: configuration.maxOutboxBytesPerConnection
            )
            let id = state.withLock { state -> ControlConnectionID in
                defer { state.nextConnection += 1 }
                return ControlConnectionID(rawValue: state.nextConnection)
            }
            let connection = ControlConnection(id: id, descriptor: client, limits: limits)
            state.withLock { $0.connections[id] = connection }
            connection.onClosed = { [weak self] in
                _ = self?.state.withLock { $0.connections.removeValue(forKey: id) }
            }
            let router = self.router
            connection.start { lines in
                var authorizer = authorizer
                for await line in lines {
                    if let request = authorizer.eventStreamRequest(line) {
                        // A stream owns the connection until the client hangs up.
                        await router.streamEvents(request, emit: { connection.send($0) }, hangup: { await connection.hangup() })
                        break
                    }
                    let (response, keepOpen) = await authorizer.respond(to: line, router: router, connection: id)
                    if let response { connection.send(response) }
                    connection.lineConsumed()
                    if !keepOpen { break }
                }
                connection.close()
            }
        }
    }

    struct Peer: Sendable {
        var pid: pid_t?
        var uid: uid_t?
    }

    static func peer(of descriptor: Int32) -> Peer {
        var uid: uid_t = 0
        var gid: gid_t = 0
        let hasUID = getpeereid(descriptor, &uid, &gid) == 0
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let hasPID = getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0
        return Peer(pid: hasPID ? pid : nil, uid: hasUID ? uid : nil)
    }
}
