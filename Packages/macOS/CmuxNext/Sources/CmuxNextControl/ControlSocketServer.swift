public import Foundation
import CmuxNextSettings
import CmuxNextDaemon
import Darwin
import CmuxNextWakeups
import CmuxNextCompat
public import CmuxNextTrace

/// The app control socket: a Unix stream socket speaking the old app's
/// line protocol (one v2 JSON request per line, one JSON response line per
/// request, plus the v1 `ping` and `auth <password>` lines the CLI sends).
///
/// All socket IO runs on private dispatch queues at utility QoS (automation,
/// below the person's input; threading-model.md) and never on the main
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
///
/// Hang watch: the accept queue is one hang-watched lane, each accept pass and each socket-path watch job (a
/// restore binds on disk) one scope of ``acceptHangDeadline``, and each connection's queue is a lane of its own (``ControlConnection``), as
/// Chrome watches each task of its IO thread (base/threading/hang_watcher.h, `ThreadType::kIOThread`).
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
        /// The socket bound at launch was discarded (quit, or an `off` mode) before it served.
        case discarded(String)

        public var description: String {
            switch self {
            case .disabled: "the control socket is disabled (access mode off)"
            case .pathTooLong(let path): "socket path is too long: \(path)"
            case .addressInUse(let path): "another process is listening on \(path)"
            case .pathOccupied(let path): "\(path) exists and is not a stale socket owned by this user"
            case .system(let call, let code): "\(call) failed: \(POSIXErrorText(code))"
            case .discarded(let path): "the socket bound at launch at \(path) was discarded before it served"
            }
        }
    }

    public let configuration: Configuration
    public let router: ControlRouter
    private let acceptQueue = DispatchQueue(label: "com.cmuxterm.next.control.accept", qos: .utility)
    /// The hang watch the accept lane and each connection's lane register on; nil watches nothing.
    private let hangs: (any HangWatchScoping)?
    /// The accept queue's lane: each accept pass is one scope.
    private let acceptWatched: HangWatchedLane?
    /// One accept pass's budget (a jank past it, a hang dump 2 s later): every call in it is non-blocking.
    static let acceptHangDeadline: Duration = .seconds(1)
    private let state = Mutex(ServerState())

    struct ServerState {
        var listener: (any DispatchSourceRead)?
        var socketIdentity: (dev: dev_t, ino: ino_t)?
        /// The path's owner lock (``lockOwner(_:)``), held while the listener is; -1: none.
        var ownerLock: Int32 = -1
        var connections: [ControlConnectionID: ControlConnection] = [:]
        var nextConnection: UInt64 = 1
        /// Spacing of accept retries while descriptors are exhausted.
        var acceptBackoff = Backoff(initial: .milliseconds(50), maximum: .seconds(2))
        var acceptSuspended = false
    }

    /// `accept(2)`, replaceable in tests.
    typealias AcceptCall = @Sendable (Int32) -> Int32
    /// `bind(2)` of a descriptor to an address (``UnixSocketAddress/bind(_:)``); tests wrap it to act while the
    /// socket file is created.
    typealias BindCall = @Sendable (Int32, UnixSocketAddress) -> Int32
    private let acceptCall: AcceptCall
    let bindCall: BindCall
    // timer-class-allow: off main: the accept retry runs on the server's queue
    private let acceptRetry = DemandTimer(owner: "ControlSocketServer.acceptRetry")
    /// Puts the socket file back when something deletes it (``ControlSocketPathWatch``).
    private let pathWatch = Mutex<[ControlSocketPathWatch]>([])

    /// - Parameter hangs: Watches each accept pass and each connection's jobs; nil (the default) watches nothing.
    ///   The app passes `TraceRuntime.shared.hangWatch`, which its hang monitor reads.
    public convenience init(configuration: Configuration, router: ControlRouter, hangs: (any HangWatchScoping)? = nil) {
        // SAFETY: with a nil address and length, accept(2) writes nothing back.
        self.init(configuration: configuration, router: router, accept: { unsafe accept($0, nil, nil) }, hangs: hangs)
    }

    init(configuration: Configuration, router: ControlRouter, accept: @escaping AcceptCall,
         bind: @escaping BindCall = { $1.bind($0) }, hangs: (any HangWatchScoping)? = nil) {
        self.configuration = configuration
        self.router = router
        self.acceptCall = accept
        self.bindCall = bind
        self.hangs = hangs
        acceptWatched = hangs.map { HangWatchedLane("control.accept", deadline: Self.acceptHangDeadline, on: $0) }
    }

    deinit {
        stop()
        acceptWatched?.unregister()
    }

    public var isRunning: Bool { state.withLock { $0.listener != nil } }

    /// The accept queue's QoS (tests).
    var acceptQueueQoS: DispatchQoS.QoSClass { acceptQueue.qos.qosClass }

    /// Open client connections.
    public var connectionCount: Int { state.withLock { $0.connections.count } }

    /// Binds and starts accepting. Throws instead of replacing a live socket.
    public func start() throws {
        guard configuration.accessMode != .off else { throw StartError.disabled }
        guard !isRunning else { return }
        let path = configuration.path
        try Self.makeStateDirectory(for: path, protectExisting: configuration.protectStateDirectory)
        let lock = try Self.lockOwner(path)
        do {
            try Self.reclaimStalePath(path)
            let (source, identity) = try makeListener()
            if let link = configuration.compatibilityLink { Self.makeLink(link, to: path) }
            serve(source, identity: identity, lock: lock)
        } catch {
            Self.releaseOwner(lock, of: path)
            throw error
        }
    }

    /// Starts accepting on `listener`, bound earlier on a lane
    /// (``bindListener(path:protectStateDirectory:compatibilityLink:accessMode:)``), which
    /// also made the compatibility link: this call publishes and resumes the accept source and starts
    /// the path watches on `acceptQueue`, with no file work. An access mode of `off` discards the
    /// listener and throws `disabled`, as ``start()`` does; a running server discards it. A listener
    /// bound for another path, file mode or link is discarded and the server binds its own
    /// (``start()``). A listener already discarded or taken throws `discarded`: its owner decided it
    /// does not serve (quit), so the server never binds again in its place.
    public func start(adopting listener: ControlSocketListener) throws {
        guard configuration.accessMode != .off else {
            listener.discard()
            throw StartError.disabled
        }
        guard !isRunning else { return listener.discard() }
        guard listener.path == configuration.path, listener.mode == configuration.accessMode.filePermissions,
              listener.compatibilityLink == configuration.compatibilityLink else {
            listener.discard()
            return try start()
        }
        guard let taken = listener.take() else { throw StartError.discarded(listener.path) }
        serve(acceptSource(taken.descriptor), identity: listener.identity, lock: taken.lock)
    }

    /// Publishes and resumes the listener's accept source, then watches the socket file (and the
    /// compatibility link) so that a deleted one is put back. The watches open their files on
    /// `acceptQueue` (``ControlSocketPathWatch/start()``).
    private func serve(_ source: any DispatchSourceRead, identity: (dev: dev_t, ino: ino_t)?, lock: Int32) {
        let path = configuration.path
        state.withLock {
            $0.listener = source
            $0.socketIdentity = identity
            $0.ownerLock = lock
        }
        router.setTransportInfo(socketPath: path, accessMode: configuration.accessMode.rawValue)
        source.resume()
        var watches = [ControlSocketPathWatch(path: path, queue: acceptQueue, lane: acceptWatched) { [weak self] in self?.restoreSocket() ?? true }]
        if let link = configuration.compatibilityLink {
            // The link yields to another app's live socket at its path: no /tmp watch for it.
            let linkWatch = ControlSocketPathWatch(path: link, queue: acceptQueue, lane: acceptWatched, yieldsToHeldPath: true) { Self.makeLink(link, to: path) }
            watches.append(linkWatch)
        }
        pathWatch.withLock { $0 = watches }
        watches.forEach { $0.start() }
    }

    /// A listening socket bound at the configured path, its read source not yet resumed, and the
    /// socket file's identity.
    private func makeListener() throws -> (any DispatchSourceRead, (dev: dev_t, ino: ino_t)?) {
        let bound = try Self.makeBoundDescriptor(path: configuration.path, mode: configuration.accessMode.filePermissions, bind: bindCall)
        return (acceptSource(bound.descriptor), bound.identity)
    }

    /// The accept source of a listening descriptor, not yet resumed; its cancel closes the descriptor.
    private func acceptSource(_ descriptor: Int32) -> any DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.watchedAccept(listener: descriptor) }
        source.setCancelHandler { close(descriptor) }
        return source
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
        let (listener, identity, connections, lock) = state.withLock { state in
            let result = (state.listener, state.socketIdentity, Array(state.connections.values), state.ownerLock)
            // A suspended source never runs its cancel handler (the listener fd would leak).
            if state.acceptSuspended { state.listener?.resume() }
            state.acceptSuspended = false
            state.listener = nil
            state.socketIdentity = nil
            state.ownerLock = -1
            state.connections = [:]
            return result
        }
        guard listener != nil || !connections.isEmpty else { return Self.releaseOwner(lock, of: configuration.path) }
        listener?.cancel()
        connections.forEach { $0.close() }
        Self.unlinkIfOwn(configuration.path, identity)
        if let link = configuration.compatibilityLink { Self.unlinkLink(link, to: configuration.path) }
        // Last: the path is free for another instance once its file is gone.
        Self.releaseOwner(lock, of: configuration.path)
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

    /// One accept pass, in one scope of the accept lane.
    private func watchedAccept(listener: Int32) {
        guard let acceptWatched else { return acceptPending(listener: listener) }
        acceptWatched.run { acceptPending(listener: listener) }
    }

    /// Accepts every waiting connection. The listener is non-blocking and
    /// its read source level-triggered, so each exit path either drained
    /// the backlog (EAGAIN: wait for readiness) or stops the source: a
    /// failure that leaves the connection queued (EMFILE, ENFILE, ENOBUFS,
    /// ENOMEM) suspends it and resumes after a capped backoff; retrying at
    /// once would spin at 100% CPU until descriptors free up.
    private func acceptPending(listener: Int32) {
        // wakeup-allow: bounded: drains the accept backlog; EAGAIN returns (readiness), other failures pause with Backoff
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
            // SAFETY: setsockopt reads the given size, MemoryLayout<Int32>.size, from `noSigPipe`, a local Int32.
            unsafe setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
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
            let connection = ControlConnection(id: id, descriptor: client, limits: limits, hangs: hangs, onClosed: { [weak self] in
                _ = self?.state.withLock { $0.connections.removeValue(forKey: id) }
                // A request still waiting for this client (a confirmation sheet) ends now.
                ControlConnectionClosures.shared.closed(id)
            })
            state.withLock { $0.connections[id] = connection }
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
        // SAFETY: getpeereid writes one uid_t and one gid_t into the locals `uid` and `gid`, live for the call.
        let hasUID = unsafe getpeereid(descriptor, &uid, &gid) == 0
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // SAFETY: getsockopt writes at most `length` bytes (the size of pid_t) into the local `pid` and the size it
        // wrote into `length`.
        let hasPID = unsafe getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0
        return Peer(pid: hasPID ? pid : nil, uid: hasUID ? uid : nil)
    }
}
