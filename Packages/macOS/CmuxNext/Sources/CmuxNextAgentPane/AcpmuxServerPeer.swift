import Darwin
import Foundation
import os
import Security
import CmuxNextCompat
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
/// their pid passed rules 1 and 2 on the unix socket first. A same-user daemon whose executable
/// path cannot be read (an update deleted the file it runs) counts as another install's under
/// the same rules, so its chats show here instead of a refusal until it exits.
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

    /// Another install's daemons that passed rules 1 and 2 (their WebSocket may be used), each
    /// by its pid and the process the pid named then (start time and audit token): a pid the
    /// kernel gives to another process after the daemon exits is not one of them.
    private static let foreignDaemons = Mutex<[pid_t: AcpmuxDaemonStop.Daemon]>([:])

    /// `LOCAL_PEERTOKEN` (sys/un.h), as ``UnixSocketPeer`` reads it.
    private static let localPeerToken: Int32 = 0x006

    /// Paths already logged as refused (one line each per launch).
    private static let refusedPaths = Mutex<Set<String>>([])


    /// `initialize`, then `method` with `params`, on one connection to `socketPath` whose server
    /// peer passed ``check(descriptor:executable:)``. Nothing is written before the check.
    /// Throws ``Refusal`` or the daemon's ``AcpmuxRPCError``.
    /// `allowForeign`: another install's daemon may answer (rules 1 to 3); never for an enroll.
    /// `deadline` nil: waits for the answer, the daemon's close of the connection (it exited) or
    /// the caller's cancel, and no thread is held while it waits (``AcpmuxSocketWait``).
    @concurrent static func call(socketPath: String, method: String, params: [String: any Sendable],
                                 executable: URL, allowForeign: Bool = false,
                                 deadline: Duration?) async throws -> [String: Any] {
        let allowForeign = allowForeign && method != "_acpmux/person_enroll"
        let exchange: @Sendable () async throws -> ResultBox = {
            try await Self.exchange(socketPath: socketPath, method: method, params: params, executable: executable,
                                    allowForeign: allowForeign)
        }
        guard let deadline else { return try await exchange().value }
        // The caller's own bound: past it the exchange is cancelled, which ends its socket wait.
        do {
            return try await withAgentPaneDeadline(deadline, label: "acpmux \(method)", exchange).value
        } catch is AgentPaneDeadlineExceeded {
            throw Refusal.timedOut
        }
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
            guard let path = executablePath(pid: pid) else { return true }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path != wanted
        }
        return foreign ? .foreign : .own
    }

    /// Every owner passes the executable rule, or is another install's daemon that passed rules
    /// 1 and 2 on its unix socket; none refuses. The scan lists only this user's processes.
    private static func judge(_ owners: [pid_t], executable: URL, what: String) -> Bool {
        let process = AcpmuxDaemonStop.kernelProcess(pid:)
        let known = foreignDaemons.withLock { $0 }
        // Forget a daemon whose pid now names another process, or none.
        let gone = known.filter { process($0.key) != $0.value }
        if !gone.isEmpty {
            foreignDaemons.withLock { daemons in
                for (pid, daemon) in gone where daemons[pid] == daemon { daemons[pid] = nil }
            }
        }
        let foreign = known.filter { gone[$0.key] == nil }
        guard let refusal = refusal(owners, executable: executable, foreign: foreign, process: process,
                                    path: executablePath(pid:)) else {
            return true
        }
        if refusedPaths.withLock({ $0.insert(what).inserted }) {
            logger.error("acpmux WebSocket \(what, privacy: .public) refused: \(refusal.description, privacy: .public); the pane does not connect")
        }
        return false
    }

    /// Why ``judge(_:executable:what:)`` refuses `owners`, nil when it passes them. Another
    /// install's daemon (`foreign`, it passed rules 1 and 2) passes before its path is read: one an
    /// update deleted the file of has no path, and it serves the chats it served on the unix socket.
    /// It passes only while its pid still names that process (`process`, its start time and audit
    /// token now): a pid reused by another process is checked by its path like any other owner.
    static func refusal(_ owners: [pid_t], executable: URL, foreign: [pid_t: AcpmuxDaemonStop.Daemon],
                        process: (pid_t) -> AcpmuxDaemonStop.Daemon?,
                        path: (pid_t) -> String?) -> Refusal? {
        guard !owners.isEmpty else { return .noPeer }
        let wanted = executable.resolvingSymlinksInPath().path
        for pid in Set(owners) {
            if let daemon = foreign[pid], let now = process(pid), now == daemon { continue }
            guard let found = path(pid) else { return .noPeer }
            let resolved = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
            if resolved != wanted { return .otherExecutable(resolved) }
        }
        return nil
    }

    /// The executable path of process `pid` (`proc_pidpath`), nil when unknown.
    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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

    /// A strict on-disk check before a Team-signed app launches its acpmux.
    /// DEV is ad-hoc and has no team to require.
    static func executableSignedByAppTeam(_ executable: URL, team: String? = ownTeam) -> Bool {
        guard let team else { return true }
        guard let requirement = requirement(team: team) else { return false }
        var code: SecStaticCode?
        let path = executable.resolvingSymlinksInPath()
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func requirement(team: String) -> SecRequirement? {
        guard !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The check on a connected unix socket: this user, then this app's acpmux or (`allowForeign`)
    /// another install's.
    static func check(descriptor: Int32, executable: URL, allowForeign: Bool = false,
                      expectedUID: uid_t = getuid()) -> Result<Match, Refusal> {
        // The peer's facts on this very descriptor (UnixSocketPeer, shared with the CUA client).
        if let peer = UnixSocketPeer(descriptor: descriptor) {
            return verdict(uid: peer.uid, executablePath: peer.executablePath, executable: executable,
                           allowForeign: allowForeign, expectedUID: expectedUID)
        }
        return verdict(uid: peerUID(descriptor), executablePath: nil, executable: executable,
                       allowForeign: allowForeign, expectedUID: expectedUID)
    }

    /// ``check(descriptor:executable:allowForeign:expectedUID:)`` on the peer's facts: `uid` nil when
    /// no credential could be read, `executablePath` nil when only the uid could (the process runs a
    /// file an update deleted, as an earlier bundle's daemon does after Sparkle replaced the app).
    /// A same-user peer whose path is unknown is another install's where the caller allows one, so
    /// it still serves its chats here: showing one session in two places is no reason to block
    /// ("there's frequently nothing wrong with showing the same session but in two different
    /// places", Leo, 2026-10-29). Rules 2 and 3 still apply to it; it never gets an enroll.
    static func verdict(uid: uid_t?, executablePath: String?, executable: URL, allowForeign: Bool,
                        expectedUID: uid_t) -> Result<Match, Refusal> {
        guard let uid else { return .failure(.noPeer) }
        guard uid == expectedUID else { return .failure(.otherUser(uid)) }
        guard let executablePath else { return allowForeign ? .success(.foreign) : .failure(.noPeer) }
        if executablePath == executable.resolvingSymlinksInPath().path { return .success(.own) }
        return allowForeign ? .success(.foreign) : .failure(.otherExecutable(executablePath))
    }

    /// The peer's uid (`LOCAL_PEERCRED`) alone, nil when it cannot be read.
    private static func peerUID(_ descriptor: Int32) -> uid_t? {
        var credentials = xucred()
        var size = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &size) == 0,
              credentials.cr_version == XUCRED_VERSION else { return nil }
        return credentials.cr_uid
    }

    /// The cmux app whose bundled acpmux runs at `path` (`cmux DEV nxdog98-v1`), else the path.
    static func holderName(executablePath path: String) -> String {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let app = parts.last(where: { $0.hasSuffix(".app") }) else { return path }
        return String(app.dropLast(".app".count))
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
        return getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 1 ? pid : nil
    }

    /// The peer process of `descriptor` (``AcpmuxDaemonStop/kernelProcess(pid:)``), nil
    /// unless its audit token is the socket's own peer token (`LOCAL_PEERTOKEN`): the pid then
    /// names that very process, not one that took the pid after the peer exited.
    private static func peerProcess(_ descriptor: Int32) -> AcpmuxDaemonStop.Daemon? {
        guard let pid = peerPID(descriptor), let process = AcpmuxDaemonStop.kernelProcess(pid: pid) else {
            return nil
        }
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, localPeerToken, &token, &size) == 0,
              token.val.5 == process.token.val.5, token.val.7 == process.token.val.7 else { return nil }
        return process
    }

    /// A connected unix socket to `socketPath`, unchecked: the caller reads its peer on this
    /// very descriptor (``UnixSocketPeer``) before it writes anything.
    static func connect(_ socketPath: String) throws -> Int32 {
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

    @concurrent private static func exchange(socketPath: String, method: String, params: [String: any Sendable],
                                             executable: URL, allowForeign: Bool) async throws -> ResultBox {
        let descriptor = try connect(socketPath)
        defer { Darwin.close(descriptor) }
        let match = try checked(descriptor, socketPath: socketPath, executable: executable, allowForeign: allowForeign)
        // Every read and write waits for readiness without a thread (``AcpmuxSocketWait``).
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
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
        try await send(payload, to: descriptor)
        var buffer = Data()
        // This connection's peer passed rule 2 and is known by its process (``peerProcess(_:)``).
        var foreignPassed = false
        while true {  // wakeup-allow: each pass waits for socket data (a dispatch source); EOF, an error or the caller's cancel ends it
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                // Another install's daemon: rule 2, its initialize lists personChallenge.
                if match == .foreign, let initialize = try AcpmuxStatusClient.detailedReply(to: 1, in: line) {
                    let features = ((initialize["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["features"] as? [String]
                    guard features?.contains("personChallenge") == true else { throw Refusal.olderDaemon }
                    if let daemon = peerProcess(descriptor) {
                        foreignDaemons.withLock { $0[daemon.pid] = daemon }
                        foreignPassed = true
                        logger.info("acpmux at \(socketPath, privacy: .public) is another cmux install's (pid \(daemon.pid, privacy: .public)); its allows stay refused unless this app keyed it")
                    }
                    continue
                }
                if let result = try AcpmuxStatusClient.detailedReply(to: 2, in: line) {
                    // The reply came before the initialize check (it cannot: replies are in order).
                    guard match == .own || foreignPassed else {
                        throw Refusal.olderDaemon
                    }
                    return ResultBox(result)
                }
            }
            guard buffer.count < 1 << 20 else { throw Refusal.closed }
            buffer += try await receive(from: descriptor)
        }
    }

    /// Writes all of `data` to the non-blocking `descriptor`, waiting for room without a thread.
    @concurrent private static func send(_ data: Data, to descriptor: Int32) async throws {
        var offset = 0
        while offset < data.count {  // wakeup-allow: each pass waits for room (a dispatch source); a write error or the cancel ends it
            try await AcpmuxSocketWait.ready(descriptor, forWrite: true)
            let sent = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.send(descriptor, base + offset, data.count - offset, 0)
            }
            if sent < 0, errno == EAGAIN || errno == EINTR { continue }
            guard sent > 0 else { throw Refusal.closed }
            offset += sent
        }
    }

    /// The next bytes from the non-blocking `descriptor`, waiting for them without a thread.
    /// The daemon's close (it exited) is `closed`.
    @concurrent private static func receive(from descriptor: Int32) async throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {  // wakeup-allow: each pass waits for data (a dispatch source); data, EOF, an error or the cancel ends it
            try await AcpmuxSocketWait.ready(descriptor, forWrite: false)
            let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw Refusal.closed }
            return Data(chunk[0..<count])
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

    static func write(_ data: Data, to descriptor: Int32, until: Date) throws {
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

    static func read(from descriptor: Int32, until: Date) throws -> Data {
        try wait(descriptor, for: Int16(POLLIN), until: until)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
        guard count > 0 else { throw Refusal.closed }
        return Data(chunk[0..<count])
    }
}
