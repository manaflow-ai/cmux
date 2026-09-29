public import Foundation
import CmuxNextSettings
import Darwin
import Synchronization

/// The app control socket: a Unix stream socket speaking the old app's
/// line protocol (one v2 JSON request per line, one JSON response line per
/// request, plus the v1 `ping` and `auth <password>` lines the CLI sends).
///
/// All socket IO runs on private dispatch queues; each connection handles
/// its requests in order on one task, and only `action.run` reaches the
/// main actor (through the router's executor).
///
/// Authorization follows the old `SocketControlMode` model: `cmuxOnly`
/// admits processes descended from this app, `automation` admits the same
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
        /// Longest accepted request line.
        public var maxLineBytes: Int

        public init(
            path: String,
            accessMode: ControlAccessMode,
            passwordVerifier: (@Sendable (String) -> Bool)? = nil,
            trustedAncestor: pid_t = getpid(),
            maxLineBytes: Int = 4 << 20
        ) {
            self.path = path
            self.accessMode = accessMode
            self.passwordVerifier = passwordVerifier
            self.trustedAncestor = trustedAncestor
            self.maxLineBytes = maxLineBytes
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
        var connections: [ObjectIdentifier: ControlConnection] = [:]
    }

    public init(configuration: Configuration, router: ControlRouter) {
        self.configuration = configuration
        self.router = router
    }

    deinit {
        stop()
    }

    public var isRunning: Bool { state.withLock { $0.listener != nil } }

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

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw StartError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        // Create the socket file with restrictive permissions from the start.
        let previousMask = umask(configuration.accessMode == .allowAll ? 0 : 0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            let code = errno
            throw code == EADDRINUSE ? StartError.addressInUse(path) : StartError.system(call: "bind", errno: code)
        }
        chmod(path, configuration.accessMode.filePermissions)
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

    /// Stops accepting, closes every connection, and removes the socket file
    /// if it is still the one this server created.
    public func stop() {
        let (listener, identity, connections) = state.withLock { state in
            let result = (state.listener, state.socketIdentity, Array(state.connections.values))
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
        return code == ECONNREFUSED ? .refused : .inconclusive(code)
    }

    // MARK: - Accepting

    private func acceptPending(listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            let peer = Self.peer(of: client)
            let authorizer = ControlAuthorizer(configuration: configuration, peer: peer)
            let connection = ControlConnection(descriptor: client, maxLineBytes: configuration.maxLineBytes)
            let key = ObjectIdentifier(connection)
            state.withLock { $0.connections[key] = connection }
            let router = self.router
            connection.start { [weak self] lines in
                var authorizer = authorizer
                for await line in lines {
                    let (response, keepOpen) = await authorizer.respond(to: line, router: router)
                    if let response { connection.send(response) }
                    if !keepOpen { break }
                }
                connection.close()
                _ = self?.state.withLock { $0.connections.removeValue(forKey: key) }
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
