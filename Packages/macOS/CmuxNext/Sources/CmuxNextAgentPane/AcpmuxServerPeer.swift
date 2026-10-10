import Darwin
import Foundation
import os
import Security
import CmuxNextCompat

/// Who answers on an acpmux socket path (cx-fcaq). Any same-uid process can shut the daemon down
/// (`_acpmux/shutdown` stays open to scripts) and bind its path, so before the app enrolls a
/// person key, or proves one, it checks the server peer of its own connection:
///
/// - the peer process's executable (`LOCAL_PEERPID`, then `proc_pidpath`, symlinks resolved) is
///   the acpmux this app runs (``AcpmuxEnvironment/executable``, the bundled binary first);
/// - when this app is Team-signed (Release, NIGHTLY, RC), the peer's code, named by its audit
///   token (`LOCAL_PEERTOKEN`, not its pid), is Apple-anchored and signed by the same team.
///
/// Anything else is refused and logged once per path; the app then never sends the key there.
nonisolated enum AcpmuxServerPeer {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case unreachable(String)
        case noPeer
        case otherExecutable(String)
        case notTeamSigned
        case closed
        case timedOut

        var description: String {
            switch self {
            case .unreachable(let why): "nothing answers on the socket (\(why))"
            case .noPeer: "the socket's peer process is unknown"
            case .otherExecutable(let path): "the socket's peer is \(path), not the acpmux this app runs"
            case .notTeamSigned: "the socket's peer is not signed by this app's team"
            case .closed: "the daemon closed the connection"
            case .timedOut: "the daemon did not answer in time"
            }
        }
    }

    /// Paths already logged as refused (one line each per launch).
    private static let refusedPaths = Mutex<Set<String>>([])

    /// `LOCAL_PEERTOKEN` (sys/un.h): the peer's audit token at connect.
    private static let localPeerToken: Int32 = 0x006

    /// `initialize`, then `method` with `params`, on one connection to `socketPath` whose server
    /// peer passed ``check(descriptor:executable:)``. Nothing is written before the check.
    /// Throws ``Refusal`` or the daemon's ``AcpmuxRPCError``.
    @concurrent static func call(socketPath: String, method: String, params: [String: any Sendable],
                                 executable: URL, deadline: Duration) async throws -> [String: Any] {
        let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        let box = try exchange(socketPath: socketPath, method: method, params: params, executable: executable,
                               until: Date().addingTimeInterval(seconds))
        return box.value
    }

    /// Whether `socketPath`'s server peer passes the check now (a probe: it connects, reads the
    /// peer, and writes nothing).
    @concurrent static func verify(socketPath: String, executable: URL) async -> Bool {
        do {
            let descriptor = try connect(socketPath)
            defer { Darwin.close(descriptor) }
            try checked(descriptor, socketPath: socketPath, executable: executable)
            return true
        } catch {
            return false
        }
    }

    /// Whether every same-uid process that listens on TCP `port` is the acpmux this app runs
    /// (cx-fcaq): the pane's WebSocket has no peer credential, so before it connects the app
    /// finds the port's listeners (a libproc scan of this user's processes' sockets) and checks
    /// each one as ``check(descriptor:executable:)`` checks a unix peer. No listener, or any
    /// other one, refuses (logged once per port).
    @concurrent static func verifyListener(port: Int, executable: URL) async -> Bool {
        let owners = listeners(port: port)
        let wanted = executable.resolvingSymlinksInPath().path
        var refusal: Refusal?
        if owners.isEmpty { refusal = .noPeer }
        for pid in owners where refusal == nil {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { refusal = .noPeer; break }
            let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
            if path != wanted { refusal = .otherExecutable(path); break }
            if let team = ownTeam, !teamSigned(pid: pid, team: team) { refusal = .notTeamSigned }
        }
        guard let refusal else { return true }
        if refusedPaths.withLock({ $0.insert("tcp:\(port)").inserted }) {
            logger.error("acpmux WebSocket listener refused on port \(port, privacy: .public): \(refusal.description, privacy: .public); the pane does not connect")
        }
        return false
    }

    /// The pids of this user's processes with a TCP socket listening on `port`.
    static func listeners(port: Int) -> [pid_t] {
        let uid = getuid()
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 32)
        let filled = pids.withUnsafeMutableBytes { bytes in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, bytes.baseAddress, Int32(bytes.count))
        }
        var owners: [pid_t] = []
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            if listens(pid: pid, port: port) { owners.append(pid) }
        }
        return owners
    }

    private static func listens(pid: pid_t, port: Int) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            // insi_lport holds the port in network byte order in its low 16 bits.
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if tcp.tcpsi_state == Int32(TSI_S_LISTEN), local == port { return true }
        }
        return false
    }

    private static func teamSigned(pid: pid_t, team: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
                == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The check on a connected unix socket.
    static func check(descriptor: Int32, executable: URL) -> Result<Void, Refusal> {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 1 else {
            return .failure(.noPeer)
        }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return .failure(.noPeer) }
        let peer = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        guard peer == executable.resolvingSymlinksInPath().path else { return .failure(.otherExecutable(peer)) }
        guard let team = ownTeam else { return .success(()) }
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, localPeerToken, &token, &tokenSize) == 0 else { return .failure(.noPeer) }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code)
                == errSecSuccess, let code else { return .failure(.notTeamSigned) }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return .failure(.notTeamSigned) }
        return .success(())
    }

    /// This app's team when it is Team-signed; nil for an ad-hoc DEV build.
    static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let info = info as? [String: Any] else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }()

    private static func checked(_ descriptor: Int32, socketPath: String, executable: URL) throws {
        if case .failure(let refusal) = check(descriptor: descriptor, executable: executable) {
            if refusedPaths.withLock({ $0.insert(socketPath).inserted }) {
                logger.error("acpmux server peer refused at \(socketPath, privacy: .public): \(refusal.description, privacy: .public); no person key goes there")
            }
            throw refusal
        }
    }

    private static func connect(_ socketPath: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { throw Refusal.unreachable("path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Refusal.unreachable(String(cString: strerror(errno))) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: @concurrent callers only; a local unix socket connect.
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let why = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw Refusal.unreachable(why)
        }
        return descriptor
    }

    private static func exchange(socketPath: String, method: String, params: [String: any Sendable],
                                 executable: URL, until: Date) throws -> ResultBox {
        let descriptor = try connect(socketPath)
        defer { Darwin.close(descriptor) }
        try checked(descriptor, socketPath: socketPath, executable: executable)
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-person", "version": "1"], "clientCapabilities": [:]],
        ]
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": method, "params": params]
        var payload = Data()
        for object in [initialize, request] {
            payload += try JSONSerialization.data(withJSONObject: object)
            payload.append(0x0A)
        }
        try write(payload, to: descriptor, until: until)
        var buffer = Data()
        while true {  // wakeup-allow: each pass waits in poll(2) for socket data; EOF, error or the deadline ends it
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let result = try AcpmuxStatusClient.detailedReply(to: 2, in: line) { return ResultBox(result) }
            }
            guard buffer.count < 1 << 20 else { throw Refusal.closed }
            buffer += try read(from: descriptor, until: until)
        }
    }

    private static func wait(_ descriptor: Int32, for events: Int16, until: Date) throws {
        let left = until.timeIntervalSinceNow
        guard left > 0 else { throw Refusal.timedOut }
        var entry = pollfd(fd: descriptor, events: events, revents: 0)
        // concurrency-allow: @concurrent callers only; poll(2) bounded by the call's deadline.
        let ready = poll(&entry, 1, Int32(min(left * 1000, Double(Int32.max))))
        guard ready > 0 else { throw ready == 0 ? Refusal.timedOut : Refusal.closed }
    }

    private static func write(_ data: Data, to descriptor: Int32, until: Date) throws {
        var offset = 0
        while offset < data.count {
            try wait(descriptor, for: Int16(POLLOUT), until: until)
            let sent = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.send(descriptor, base + offset, data.count - offset, 0)
            }
            guard sent > 0 else { throw Refusal.closed }
            offset += sent
        }
    }

    private static func read(from descriptor: Int32, until: Date) throws -> Data {
        try wait(descriptor, for: Int16(POLLIN), until: until)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
        guard count > 0 else { throw Refusal.closed }
        return Data(chunk[0..<count])
    }
}
