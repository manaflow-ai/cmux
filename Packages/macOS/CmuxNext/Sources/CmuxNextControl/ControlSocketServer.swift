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

    /// Removes a leftover socket from a crashed run. Refuses when a process
    /// still accepts on it, when it is not a socket, or when another user
    /// owns it.
    static func reclaimStalePath(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw StartError.pathOccupied(path) }
        if socketAcceptsConnections(path) { throw StartError.addressInUse(path) }
        unlink(path)
    }

    static func socketAcceptsConnections(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
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

/// Per-connection authorization state, owned by the connection's task.
struct ControlAuthorizer: Sendable {
    let configuration: ControlSocketServer.Configuration
    let peer: ControlSocketServer.Peer
    var isPasswordAuthenticated = false

    init(configuration: ControlSocketServer.Configuration, peer: ControlSocketServer.Peer) {
        self.configuration = configuration
        self.peer = peer
    }

    static let accessDenied = "ERROR: Access denied - only processes started inside cmux can connect"

    /// The response line for one request line, and whether to keep the
    /// connection open.
    mutating func respond(to rawLine: String, router: ControlRouter) async -> (String?, Bool) {
        let line = Self.unwrapEnvelopes(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !line.isEmpty else { return (nil, true) }
        guard isPeerAdmitted else { return (Self.accessDenied, false) }

        let isJSON = line.hasPrefix("{")
        let loweredVerb = isJSON ? "" : line.split(separator: " ", maxSplits: 1).first.map { $0.lowercased() } ?? ""
        if configuration.accessMode == .password {
            if loweredVerb == "auth" {
                return (loginV1(line), true)
            }
            if isJSON, case .success(let request) = ControlRouter.decode(line), request.method == "auth.login" {
                return (loginV2(request), true)
            }
            if !isPasswordAuthenticated {
                if isJSON {
                    let id = (try? JSONValue.parse(Data(line.utf8)))?["id"]
                    return (ControlRouter.encode(id: id, error: ControlError(code: "auth_required", message: "Authentication required. Send auth <password> first.")), true)
                }
                return ("ERROR: Authentication required — send auth <password> first", true)
            }
        } else if loweredVerb == "auth" {
            return ("OK: Authentication not required", true)
        } else if isJSON, case .success(let request) = ControlRouter.decode(line), request.method == "auth.login" {
            return (ControlRouter.encode(id: request.id, result: .success(["authenticated": true])), true)
        }
        return (await router.response(forLine: line), true)
    }

    var isPeerAdmitted: Bool {
        switch configuration.accessMode {
        case .off:
            return false
        case .allowAll:
            return true
        case .automation, .password:
            return peer.uid == getuid()
        case .cmuxOnly:
            guard let pid = peer.pid else { return false }
            return Self.isProcess(pid, descendantOf: configuration.trustedAncestor)
        }
    }

    private mutating func loginV1(_ line: String) -> String {
        let provided = line.count > 5 ? String(line.dropFirst(5)) : ""
        guard !provided.isEmpty else { return "ERROR: Missing password. Usage: auth <password>" }
        guard configuration.passwordVerifier?(provided) == true else { return "ERROR: Invalid password" }
        isPasswordAuthenticated = true
        return "OK: Authenticated"
    }

    private mutating func loginV2(_ request: ControlRequest) -> String {
        guard let provided = request.params["password"]?.stringValue else {
            return ControlRouter.encode(id: request.id, error: .invalidParams("auth.login requires params.password"))
        }
        guard configuration.passwordVerifier?(provided) == true else {
            return ControlRouter.encode(id: request.id, error: ControlError(code: "auth_failed", message: "Invalid password"))
        }
        isPasswordAuthenticated = true
        return ControlRouter.encode(id: request.id, result: .success(["authenticated": true]))
    }

    /// Strips the CLI's optional line prefixes: the capability envelope
    /// (`_cmux_capability_v1 <token> `) and the automation origin
    /// (`__cmux_automation_origin <base64> `). cmux-next does not verify
    /// capabilities yet, so a capability never widens access.
    static func unwrapEnvelopes(_ line: String) -> String {
        var current = Substring(line)
        for prefix in ["_cmux_capability_v1 ", "__cmux_automation_origin "] where current.hasPrefix(prefix) {
            let rest = current.dropFirst(prefix.count)
            guard let space = rest.firstIndex(of: " ") else { return String(current) }
            current = rest[rest.index(after: space)...]
        }
        return String(current)
    }

    static func isProcess(_ pid: pid_t, descendantOf ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<128 {
            if current == ancestor { return true }
            if current <= 1 { return false }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            let parent = info.kp_eproc.e_ppid
            if parent == current || parent < 0 { return false }
            current = parent
        }
        return false
    }
}

/// One accepted client. Reads with a dispatch source on a private serial
/// queue, splits lines, and hands them to a single consumer task; writes are
/// queued on the same queue so responses keep request order.
final class ControlConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let maxLineBytes: Int
    private let queue = DispatchQueue(label: "com.cmuxterm.next.control.connection")
    // Queue-confined.
    private var source: (any DispatchSourceRead)?
    private var buffer = Data()
    private var continuation: AsyncStream<String>.Continuation?
    private var consumer: Task<Void, Never>?
    private var isClosed = false
    private var isReadSuspended = false

    init(descriptor: Int32, maxLineBytes: Int) {
        self.descriptor = descriptor
        self.maxLineBytes = maxLineBytes
    }

    func start(consume: @escaping @Sendable (AsyncStream<String>) async -> Void) {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        queue.async { [self] in
            self.continuation = continuation
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
            self.source = source
            source.resume()
            consumer = Task { await consume(stream) }
        }
    }

    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [self] in
            guard !isClosed else { return }
            writeAll(data)
        }
    }

    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            continuation?.finish()
            continuation = nil
            // A suspended source must be resumed before it can be cancelled.
            if isReadSuspended { source?.resume() }
            source?.cancel()
            source = nil
        }
    }

    // MARK: - Queue-confined

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: count)
                emitLines()
                if buffer.count > maxLineBytes {
                    writeAll(Data((ControlRouter.encode(id: nil, error: ControlError(code: "request_too_large", message: "Request line exceeds \(maxLineBytes) bytes")) + "\n").utf8))
                    finishInput()
                    return
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            // EOF or error: let the consumer drain what it has, then close.
            finishInput()
            return
        }
    }

    private func emitLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            continuation?.yield(String(decoding: lineData, as: UTF8.self))
        }
    }

    /// Stops reading (EOF, error, or oversized line) but keeps the
    /// descriptor open so queued responses still reach a half-closed client.
    private func finishInput() {
        continuation?.finish()
        continuation = nil
        if let source, !isReadSuspended {
            source.suspend()
            isReadSuspended = true
        }
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    // Bounded wait for a slow reader; a stuck client is dropped.
                    guard poll(&descriptorSet, 1, 5_000) > 0 else { return }
                } else {
                    return
                }
            }
        }
    }
}
