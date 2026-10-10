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
/// Another install of cmux (lead decision 2026-10-10): NIGHTLY and Release share `~/.acpmux`, so
/// the daemon there may be the other app's. A Team-signed build accepts such a daemon only when
/// all of these hold, and in DEV (ad hoc) the path check alone decides:
/// 1. the peer's code satisfies `identifier "<the code-signing identifier of this app's own
///    acpmux binary>" and anchor apple generic and certificate leaf[subject.OU] = "<team>"`
///    (not any team-signed binary: another team tool, or an old cmux binary, is refused);
/// 2. its `initialize` reply lists the `personChallenge` feature (cx-fcaq or later): an older
///    signed acpmux predates the challenge proof and is refused;
/// 3. it gets only the challenge proof, never `_acpmux/person_enroll`: enroll goes only to a
///    daemon at this app's own executable path (``call(socketPath:method:params:executable:allowForeign:deadline:)``
///    with `allowForeign` false). With one key per daemon such a daemon holds no key of this
///    app, so its allows are refused; the app logs why.
/// The pane's WebSocket listener and accepted end are accepted as another install's only when
/// their pid passed rules 1 and 2 on the unix socket first.
///
/// Anything else is refused and logged once per path; the app then never sends the key there.
///
/// Residual (DEV, an ad-hoc signed build): the check is the executable path only, so a same-uid
/// process that runs that very binary (the bundled acpmux, started by an agent with its own
/// home) passes it. Such a daemon holds no key of this app (one key per daemon instance, given
/// only to a daemon this app started or enrolled), and a proof names its transport, so it learns
/// nothing it can use against the app's own daemon.
nonisolated enum AcpmuxServerPeer {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case unreachable(String)
        case noPeer
        case otherExecutable(String)
        case notTeamSigned
        case closed
        case timedOut
        case olderDaemon

        var description: String {
            switch self {
            case .unreachable(let why): "nothing answers on the socket (\(why))"
            case .noPeer: "the socket's peer process is unknown"
            case .otherExecutable(let path): "the socket's peer is \(path), not the acpmux this app runs"
            case .notTeamSigned: "the socket's peer is not signed by this app's team"
            case .closed: "the daemon closed the connection"
            case .timedOut: "the daemon did not answer in time"
            case .olderDaemon: "the other install's acpmux predates the person challenge"
            }
        }
    }

    /// What a passing peer is: the acpmux at this app's own path, or another install's.
    enum Match: Equatable { case own, foreign }

    /// Pids of another install's daemons that passed rules 1 and 2 (their WebSocket may be used).
    private static let foreignDaemons = Mutex<Set<pid_t>>([])

    /// Paths already logged as refused (one line each per launch).
    private static let refusedPaths = Mutex<Set<String>>([])

    /// `LOCAL_PEERTOKEN` (sys/un.h): the peer's audit token at connect.
    private static let localPeerToken: Int32 = 0x006

    /// `initialize`, then `method` with `params`, on one connection to `socketPath` whose server
    /// peer passed ``check(descriptor:executable:)``. Nothing is written before the check.
    /// Throws ``Refusal`` or the daemon's ``AcpmuxRPCError``.
    /// `allowForeign`: another install's daemon may answer (rules 1 to 3); never for an enroll.
    @concurrent static func call(socketPath: String, method: String, params: [String: any Sendable],
                                 executable: URL, allowForeign: Bool = false,
                                 deadline: Duration) async throws -> [String: Any] {
        let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        let box = try exchange(socketPath: socketPath, method: method, params: params, executable: executable,
                               allowForeign: allowForeign && method != "_acpmux/person_enroll",
                               until: Date().addingTimeInterval(seconds))
        return box.value
    }

    /// Whether `socketPath`'s server peer passes the check now (a probe: it connects, reads the
    /// peer, and writes nothing).
    @concurrent static func verify(socketPath: String, executable: URL) async -> Bool {
        do {
            let descriptor = try connect(socketPath)
            defer { Darwin.close(descriptor) }
            return try checked(descriptor, socketPath: socketPath, executable: executable, allowForeign: false) == .own
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
        let owners = tcpSockets().filter { $0.listening && $0.localPort == port }.map(\.pid)
        return judge(owners, executable: executable, what: "listener on port \(port)")
    }

    /// Watch item (cx-fcaq review P3-2): `tcpSockets()` reads every socket of every process of
    /// this user (proc_pidinfo per process, proc_pidfdinfo per socket) twice per pane connect.
    /// Measured cost is not known yet; if pane connects show it, scan only processes whose
    /// executable is the acpmux this app runs, plus this process.
    ///
    /// After the pane connected (cx-fcaq): the process that holds the accepted end of each of
    /// this process's connections to `port` (local port `port`, remote port = ours) is the
    /// acpmux this app runs, so the scan before connecting and the connect are not separated.
    /// Nil: refused. Otherwise whether the accepted end is this app's own acpmux or another
    /// cmux install's (the pane then says its allows stay with that app).
    @concurrent static func verifyAccepted(port: Int, executable: URL) async -> Match? {
        let all = tcpSockets()
        let me = getpid()
        let ours = all.filter { $0.pid == me && $0.established && $0.remotePort == port }.map(\.localPort)
        var owners: [pid_t] = []
        for local in ours {
            let peers = all.filter { $0.pid != me && $0.established && $0.localPort == port && $0.remotePort == local }
            if peers.isEmpty { owners = []; break }
            owners += peers.map(\.pid)
        }
        if ours.isEmpty { owners = [] }
        guard judge(owners, executable: executable, what: "accepted end on port \(port)") else { return nil }
        let wanted = executable.resolvingSymlinksInPath().path
        let foreign = owners.contains { pid in
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
            return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path != wanted
        }
        return foreign ? .foreign : .own
    }

    /// Every owner passes the executable (and, Team-signed, the signature) rule, or is another
    /// install's daemon that passed rules 1 and 2 on its unix socket; none refuses.
    private static func judge(_ owners: [pid_t], executable: URL, what: String) -> Bool {
        let wanted = executable.resolvingSymlinksInPath().path
        let foreign = foreignDaemons.withLock { $0 }
        var refusal: Refusal?
        if owners.isEmpty { refusal = .noPeer }
        for pid in Set(owners) where refusal == nil {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { refusal = .noPeer; break }
            let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
            if path != wanted, !foreign.contains(pid) { refusal = .otherExecutable(path); break }
            if let team = ownTeam, !teamSigned(pid: pid, team: team, identifier: path == wanted ? nil : ownIdentifier(executable)) {
                refusal = .notTeamSigned
            }
        }
        guard let refusal else { return true }
        if refusedPaths.withLock({ $0.insert(what).inserted }) {
            logger.error("acpmux WebSocket \(what, privacy: .public) refused: \(refusal.description, privacy: .public); the pane does not connect")
        }
        return false
    }

    struct TCPSocket {
        var pid: pid_t
        var localPort: Int
        var remotePort: Int
        var listening: Bool
        var established: Bool
    }

    /// This user's processes' TCP sockets (libproc).
    static func tcpSockets() -> [TCPSocket] {
        let uid = getuid()
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 32)
        let filled = pids.withUnsafeMutableBytes { bytes in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, bytes.baseAddress, Int32(bytes.count))
        }
        var out: [TCPSocket] = []
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            out += tcpSockets(of: pid)
        }
        return out
    }

    private static func tcpSockets(of pid: pid_t) -> [TCPSocket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        var out: [TCPSocket] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            // The ports are in network byte order in the low 16 bits.
            let port = { (raw: Int32) in Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))) }
            out.append(TCPSocket(pid: pid, localPort: port(tcp.tcpsi_ini.insi_lport),
                                 remotePort: port(tcp.tcpsi_ini.insi_fport),
                                 listening: tcp.tcpsi_state == Int32(TSI_S_LISTEN),
                                 established: tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED)))
        }
        return out
    }

    private static func teamSigned(pid: pid_t, team: String, identifier: String?) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
                == errSecSuccess, let code else { return false }
        return satisfies(code, team: team, identifier: identifier)
    }

    /// The team requirement, with the exact code-signing identifier when one is given (rule 1).
    private static func satisfies(_ code: SecCode, team: String, identifier: String?) -> Bool {
        var text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        if let identifier {
            guard identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else { return false }
            text = "identifier \"\(identifier)\" and " + text
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The code-signing identifier of this app's own acpmux binary (on disk), cached per path.
    private static let identifiers = Mutex<[String: String]>([:])
    static func ownIdentifier(_ executable: URL) -> String? {
        let path = executable.resolvingSymlinksInPath().path
        if let known = identifiers.withLock({ $0[path] }) { return known }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any], let identifier = info[kSecCodeInfoIdentifier as String] as? String else {
            return nil
        }
        identifiers.withLock { $0[path] = identifier }
        return identifier
    }

    /// The check on a connected unix socket.
    static func check(descriptor: Int32, executable: URL, allowForeign: Bool = false) -> Result<Match, Refusal> {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 1 else {
            return .failure(.noPeer)
        }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return .failure(.noPeer) }
        let peer = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        let own = peer == executable.resolvingSymlinksInPath().path
        // DEV (ad hoc): the path alone decides; another install is never accepted.
        guard let team = ownTeam else { return own ? .success(.own) : .failure(.otherExecutable(peer)) }
        guard own || allowForeign else { return .failure(.otherExecutable(peer)) }
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, localPeerToken, &token, &tokenSize) == 0 else { return .failure(.noPeer) }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code)
                == errSecSuccess, let code else { return .failure(.notTeamSigned) }
        // Another install: rule 1, the exact identifier of this app's own acpmux.
        let identifier = own ? nil : ownIdentifier(executable)
        if !own, identifier == nil { return .failure(.notTeamSigned) }
        guard satisfies(code, team: team, identifier: identifier) else { return .failure(.notTeamSigned) }
        return .success(own ? .own : .foreign)
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

    @discardableResult
    private static func checked(_ descriptor: Int32, socketPath: String, executable: URL,
                                allowForeign: Bool) throws -> Match {
        switch check(descriptor: descriptor, executable: executable, allowForeign: allowForeign) {
        case .success(let match): return match
        case .failure(let refusal):
            if refusedPaths.withLock({ $0.insert(socketPath).inserted }) {
                logger.error("acpmux server peer refused at \(socketPath, privacy: .public): \(refusal.description, privacy: .public); no person key goes there")
            }
            throw refusal
        }
    }

    /// The peer's pid (`LOCAL_PEERPID`).
    private static func peerPID(_ descriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 1 ? pid : nil
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
                                 executable: URL, allowForeign: Bool, until: Date) throws -> ResultBox {
        let descriptor = try connect(socketPath)
        defer { Darwin.close(descriptor) }
        let match = try checked(descriptor, socketPath: socketPath, executable: executable, allowForeign: allowForeign)
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
                // Another install's daemon: rule 2, its initialize lists personChallenge.
                if match == .foreign, let initialize = try AcpmuxStatusClient.detailedReply(to: 1, in: line) {
                    let features = ((initialize["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["features"] as? [String]
                    guard features?.contains("personChallenge") == true else { throw Refusal.olderDaemon }
                    if let pid = peerPID(descriptor) {
                        foreignDaemons.withLock { $0.insert(pid) }
                        logger.info("acpmux at \(socketPath, privacy: .public) is another cmux install's (pid \(pid, privacy: .public)); its allows stay refused unless this app keyed it")
                    }
                    continue
                }
                if let result = try AcpmuxStatusClient.detailedReply(to: 2, in: line) {
                    // The reply came before the initialize check (it cannot: replies are in order).
                    guard match == .own || foreignDaemons.withLock({ set in peerPID(descriptor).map(set.contains) ?? false }) else {
                        throw Refusal.olderDaemon
                    }
                    return ResultBox(result)
                }
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
