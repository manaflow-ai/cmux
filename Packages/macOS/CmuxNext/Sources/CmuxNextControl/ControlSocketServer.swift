public import Foundation
import CmuxNextSettings
import Darwin
import CmuxNextWakeups
import CmuxNextCompat

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
/// binary that hosts every terminal), and `automation` admits the same user.
/// The socket file is always 0600.
public final class ControlSocketServer: Sendable {
    public struct Configuration: Sendable {
        public var path: String
        public var accessMode: ControlAccessMode
        /// Tightens and validates an existing parent as cmux's canonical state directory.
        public var protectStateDirectory: Bool
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
        /// A symlink to `path` kept at the socket's old name, for tools that
        /// still use it; made only where nothing is, removed on stop.
        public var compatibilityLink: String?

        public init(
            path: String,
            accessMode: ControlAccessMode,
            protectStateDirectory: Bool = false,
            trustedAncestor: pid_t = getpid(),
            trustedExecutables: Set<String> = [],
            maxLineBytes: Int = 4 << 20,
            maxQueuedLinesPerConnection: Int = 64,
            maxOutboxBytesPerConnection: Int = 8 << 20,
            compatibilityLink: String? = nil
        ) {
            self.path = path
            self.accessMode = accessMode
            self.protectStateDirectory = protectStateDirectory
            self.trustedAncestor = trustedAncestor
            self.trustedExecutables = trustedExecutables
            self.maxLineBytes = maxLineBytes
            self.maxQueuedLinesPerConnection = maxQueuedLinesPerConnection
            self.maxOutboxBytesPerConnection = maxOutboxBytesPerConnection
            self.compatibilityLink = compatibilityLink
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
    let bindCall: BindCall
    private let acceptRetry = DemandTimer(owner: "ControlSocketServer.acceptRetry")
    /// Puts the socket file back when something deletes it (``ControlSocketPathWatch``).
    private let pathWatch = Mutex<[ControlSocketPathWatch]>([])

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
        try Self.makeStateDirectory(for: path, protectExisting: configuration.protectStateDirectory)
        try Self.reclaimStalePath(path)
        let (source, identity) = try makeListener()
        state.withLock {
            $0.listener = source
            $0.socketIdentity = identity
        }
        router.setTransportInfo(socketPath: path, accessMode: configuration.accessMode.rawValue)
        source.resume()
        var watches = [ControlSocketPathWatch(path: path, queue: acceptQueue) { [weak self] in self?.restoreSocket() ?? true }]
        if let link = configuration.compatibilityLink {
            Self.makeLink(link, to: path)
            // The link yields to another app's live socket at its path: no /tmp watch for it.
            watches.append(ControlSocketPathWatch(path: link, queue: acceptQueue, yieldsToHeldPath: true) { Self.makeLink(link, to: path) })
        }
        pathWatch.withLock { $0 = watches }
        watches.forEach { $0.start() }
    }

    /// A listening socket bound at the configured path, its read source not yet resumed, and the
    /// socket file's identity.
    private func makeListener() throws -> (any DispatchSourceRead, (dev: dev_t, ino: ino_t)?) {
        let path = configuration.path
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
        let identity = lstat(path, &info) == 0 ? (dev: info.st_dev, ino: info.st_ino) : nil
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(listener: descriptor) }
        source.setCancelHandler { close(descriptor) }
        shouldClose = false
        return (source, identity)
    }

    /// Binds a new listener at the path ``ControlSocketPathWatch`` found
    /// missing and returns whether the socket is back. The bind's
    /// `RENAME_EXCL` loses to anyone who created the path meanwhile, so another
    /// server's socket or a file is never replaced. Runs on `acceptQueue`, the
    /// queue of the old listener's accept handler, so the swap never races an
    /// accept pausing on descriptor exhaustion.
    private func restoreSocket() -> Bool {
        guard isRunning else { return true }
        guard let made = try? makeListener() else { return false }
        let (source, identity) = made
        let old: (any DispatchSourceRead)? = state.withLock { state in
            guard let old = state.listener else { return nil }  // stopped meanwhile
            if state.acceptSuspended { old.resume() }  // a suspended source never runs its cancel handler
            state.acceptSuspended = false
            state.acceptBackoff.reset()
            // Resumed before it is published: stop() may cancel it from another
            // thread, and an inactive source must never be cancelled or released.
            source.resume()
            state.listener = source
            state.socketIdentity = identity
            return old
        }
        guard let old else {
            source.resume()  // never resumed above; cancel needs an active source to close the fd
            source.cancel()
            Self.unlinkIfOwn(configuration.path, identity)
            return true
        }
        acceptRetry.cancel()
        WakeupLedger.shared.record("ControlSocketServer.restore", reason: "socket file restored")
        old.cancel()
        return true
    }

    /// Closes the listener and every connection, then binds the socket again
    /// at the same path and mode (Restart CLI Listener). Throws what
    /// ``start()`` throws, leaving the server stopped.
    public func restart() throws {
        stop()
        try start()
    }

    /// Stops accepting, closes every connection, and removes the socket file
    /// if it is still the one this server created.
    public func stop() {
        acceptRetry.cancel()
        pathWatch.withLock { watches in
            watches.forEach { $0.stop() }
            watches = []
        }
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
        Self.unlinkIfOwn(configuration.path, identity)
        if let link = configuration.compatibilityLink { Self.unlinkLink(link, to: configuration.path) }
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
                // A request still waiting for this client (a confirmation sheet) ends now.
                ControlConnectionClosures.shared.closed(id)
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
