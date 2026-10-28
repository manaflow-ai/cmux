import Darwin
import Foundation
import os
import Security
import CmuxNextCompat
import struct CmuxNextDaemon.POSIXErrorText
import struct CmuxNextDaemon.UnixSocketAddress
import CmuxNextWakeups

/// Who answers on an acpmux socket path (cx-fcaq). Before the app enrolls a person key, or
/// proves one, it checks the server peer of its own connection:
///
/// - the peer runs as this user (`LOCAL_PEERCRED`): another user's process is refused;
/// - the peer process's executable (`LOCAL_PEERPID`, then `proc_pidpath`, symlinks resolved) is
///   the acpmux this app runs (``AcpmuxEnvironment/executable``, the bundled binary first), or,
///   where the caller allows it, another install's acpmux.
///
/// No code-signing gate on the peer: "acpmux is too belt and suspenders there" (Leo,
/// 2026-10-23). A same-user socket is usable whatever signs the binary behind it; the team
/// requirement refused a same-user daemon ("the socket's peer is not signed by this app's
/// team") and bought nothing against another user, whom the uid check already stops. The
/// on-disk team check before the app launches its own acpmux (``executableSignedByAppTeam(_:team:)``)
/// stays: that decides what the app runs, not who it talks to.
///
/// Another install of cmux (lead decision 2026-10-10): NIGHTLY shares `~/.acpmux` with older builds and
/// other copies of NIGHTLY (per-build homes since cx-is1kf.3), so the daemon there may be another app's.
/// Such a daemon is accepted only when:
/// 1. the caller allows another install (``call(socketPath:method:params:executable:allowForeign:deadline:)``
///    with `allowForeign`);
/// 2. its `initialize` reply lists the `personChallenge` feature (cx-fcaq or later): an older
///    acpmux predates the challenge proof and is refused;
/// 3. it gets only the challenge proof, never `_acpmux/person_enroll`: enroll goes only to a
///    daemon at this app's own executable path. With one key per daemon such a daemon holds no
///    key of this app, so its allows are refused; the app logs why.
/// The pane's WebSocket listener and accepted end are accepted as another install's only when
/// their pid passed rules 1 and 2 on the unix socket first.
///
/// Anything else is refused and logged once per path; the app then never sends the key there.
///
/// Residual: a same-uid process that runs the acpmux binary at this app's path (started by an
/// agent with its own home) passes. Such a daemon holds no key of this app (one key per daemon
/// instance, given only to a daemon this app started or enrolled), and a proof names its
/// transport, so it learns nothing it can use against the app's own daemon.
nonisolated enum AcpmuxServerPeer {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case unreachable(String)
        case noPeer
        case otherUser(uid_t)
        case otherExecutable(String)
        case closed
        case timedOut
        case olderDaemon

        var description: String {
            switch self {
            case .unreachable(let why): "nothing answers on the socket (\(why))"
            case .noPeer: "the socket's peer process is unknown"
            case .otherUser(let uid): "the socket's peer runs as uid \(uid), not this user"
            case .otherExecutable(let path): "the socket's peer is \(path), not the acpmux this app runs"
            case .closed: "the daemon closed the connection"
            case .timedOut: "the daemon did not answer in time"
            case .olderDaemon: "the other install's acpmux predates the person challenge"
            }
        }

        /// A socket that vanished while a daemon hands off is expected to come back shortly.
        /// Other refusals name a live peer or a protocol problem and must remain visible.
        var isTransientRestart: Bool {
            if case .unreachable = self { return true }
            return false
        }
    }

    /// What a passing peer is: the acpmux at this app's own path, or another install's.
    enum Match: Equatable { case own, foreign }

    /// Pids of another install's daemons that passed rules 1 and 2 (their WebSocket may be used).
    private static let foreignDaemons = Mutex<Set<pid_t>>([])

    /// Paths already logged as refused (one line each per launch).
    private static let refusedPaths = Mutex<Set<String>>([])


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

    // No probe-then-connect helper (cx-aocz review P1): a check on one connection says nothing
    // about the next one. Callers check the connection they write on (``connectChecked``,
    // ``call(socketPath:method:params:executable:allowForeign:deadline:)``, ``AcpmuxCheckedLine``).

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
            // SAFETY: proc_pidpath writes at most buffer.count bytes into the array's own storage, lent for the call.
            guard unsafe proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
            let running = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: running).resolvingSymlinksInPath().path != wanted
        }
        return foreign ? .foreign : .own
    }

    /// Every owner passes the executable rule, or is another install's daemon that passed rules
    /// 1 and 2 on its unix socket; none refuses. The scan lists only this user's processes.
    private static func judge(_ owners: [pid_t], executable: URL, what: String) -> Bool {
        let wanted = executable.resolvingSymlinksInPath().path
        let foreign = foreignDaemons.withLock { $0 }
        var refusal: Refusal?
        if owners.isEmpty { refusal = .noPeer }
        for pid in Set(owners) where refusal == nil {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            // SAFETY: proc_pidpath writes at most buffer.count bytes into the array's own storage, lent for the call.
            guard unsafe proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { refusal = .noPeer; break }
            let running = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let path = URL(fileURLWithPath: running).resolvingSymlinksInPath().path
            if path != wanted, !foreign.contains(pid) { refusal = .otherExecutable(path); break }
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
        // SAFETY: with no buffer (nil, 0) proc_listpids only answers the byte count it needs.
        let needed = unsafe proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 32)
        // SAFETY: proc_listpids writes at most the given byte size, exactly the array's (pids.count pids), into the
        // array's own storage, lent for the call.
        let filled = unsafe proc_listpids(UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [TCPSocket] = []
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            out += tcpSockets(of: pid)
        }
        return out
    }

    private static func tcpSockets(of pid: pid_t) -> [TCPSocket] {
        // SAFETY: with no buffer (nil, 0) proc_pidinfo only answers the byte count it needs.
        let bytes = unsafe blockingProcPidInfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        // SAFETY: proc_pidinfo writes at most the given byte size, exactly the array's (fds.count entries of `stride`
        // bytes), into the array's own storage, lent for the call.
        let filled = unsafe blockingProcPidInfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        var out: [TCPSocket] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            // SAFETY: proc_pidfdinfo writes at most `size` bytes, one socket_fdinfo, into `info`, a local.
            guard unsafe proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
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

    /// A strict on-disk check before a Team-signed app launches its acpmux.
    /// DEV is ad-hoc and has no team to require. `team` is this app's (``SigningTeamInstall/team``, read
    /// on the system lane at launch). The answer is kept per version of the file (``StaticCodeValidityCache``).
    /// Blocks (stat calls, and the check on a miss): the app resolves its acpmux on its system lane
    /// (`AppEnvironment.appAcpmux`), never on the main thread.
    static func executableSignedByAppTeam(_ executable: URL, team: String?) -> Bool {
        guard let team else { return true }
        guard let requirement = requirement(team: team) else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return StaticCodeValidityCache.process.isValid(executable.resolvingSymlinksInPath(), flags: flags, requirement: requirement)
    }

    /// The requirement text of `team`'s Developer ID, or nil when `team` is not a plain identifier.
    private static func requirement(team: String) -> String? {
        guard !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// The check on a connected unix socket: this user, then this app's acpmux or (`allowForeign`)
    /// another install's.
    static func check(descriptor: Int32, executable: URL, allowForeign: Bool = false,
                      expectedUID: uid_t = getuid()) -> Result<Match, Refusal> {
        // The peer's facts on this very descriptor (UnixSocketPeer, shared with the CUA client).
        guard let peer = UnixSocketPeer(descriptor: descriptor) else { return .failure(.noPeer) }
        guard peer.uid == expectedUID else { return .failure(.otherUser(peer.uid)) }
        if peer.runs(executable) { return .success(.own) }
        return allowForeign ? .success(.foreign) : .failure(.otherExecutable(peer.executablePath))
    }

    /// The cmux app whose bundled acpmux runs at `path` (`cmux DEV nxdog98-v1`), else the path.
    static func holderName(executablePath path: String) -> String {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let app = parts.last(where: { $0.hasSuffix(".app") }) else { return path }
        return String(app.dropLast(".app".count))
    }

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

    /// A connected unix socket to `socketPath` whose server peer passed the check (own path
    /// only): the caller writes on THIS descriptor, never on another connection checked
    /// earlier (a squatter could take the path between a probe and a connect).
    static func connectChecked(socketPath: String, executable: URL) throws -> Int32 {
        let descriptor = try connect(socketPath)
        do {
            guard try checked(descriptor, socketPath: socketPath, executable: executable, allowForeign: false) == .own else {
                throw Refusal.otherExecutable(socketPath)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    /// Who answers on `socketPath`, read from a connection's own peer facts and closed at once
    /// (nothing is written). Nil when nothing answers or the facts cannot be read.
    static func socketPeer(socketPath: String) -> UnixSocketPeer? {
        guard let descriptor = try? connect(socketPath) else { return nil }
        defer { Darwin.close(descriptor) }
        return UnixSocketPeer(descriptor: descriptor)
    }

    /// The peer's pid (`LOCAL_PEERPID`).
    private static func peerPID(_ descriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        // SAFETY: getsockopt writes at most `size` bytes (one pid_t) into `pid` and the size it wrote into `size`;
        // both are locals.
        return unsafe getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 1 ? pid : nil
    }

    private static func connect(_ socketPath: String) throws -> Int32 {
        guard let address = UnixSocketAddress(path: socketPath) else { throw Refusal.unreachable("path too long") }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Refusal.unreachable(POSIXErrorText(errno).description) }
        var noSigPipe: Int32 = 1
        // SAFETY: setsockopt reads the size it is given from `noSigPipe`, a local Int32.
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        // concurrency-allow: @concurrent callers only; a local unix socket connect.
        guard address.connect(descriptor) == 0 else {
            let why = POSIXErrorText(errno).description
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
        while true {  // wakeup-allow: bounded each pass waits in poll(2) for socket data; EOF, an error or the call's deadline ends it
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
        // SAFETY: poll reads and writes the one pollfd it is told of, `entry`, a local.
        let ready = unsafe poll(&entry, 1, Int32(min(left * 1000, Double(Int32.max))))
        guard ready > 0 else { throw ready == 0 ? Refusal.timedOut : Refusal.closed }
    }

    private static func write(_ data: Data, to descriptor: Int32, until: Date) throws {
        var offset = 0
        while offset < data.count {
            try wait(descriptor, for: Int16(POLLOUT), until: until)
            // SAFETY: `bytes` is the data's contiguous storage, valid only inside this closure, which never lets a
            // pointer out; 0 <= offset < data.count (the loop's condition), so the send covers the data.count - offset
            // bytes from base + offset to the buffer's end.
            let sent = unsafe data.withUnsafeBytes { bytes -> Int in
                guard let base = unsafe bytes.baseAddress else { return -1 }
                return unsafe Darwin.send(descriptor, base + offset, data.count - offset, 0)
            }
            guard sent > 0 else { throw Refusal.closed }
            offset += sent
        }
    }

    private static func read(from descriptor: Int32, until: Date) throws -> Data {
        try wait(descriptor, for: Int16(POLLIN), until: until)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        // SAFETY: recv writes at most chunk.count bytes into the array's own storage, lent for the call.
        let count = unsafe Darwin.recv(descriptor, &chunk, chunk.count, 0)
        guard count > 0 else { throw Refusal.closed }
        return Data(chunk[0..<count])
    }
}
