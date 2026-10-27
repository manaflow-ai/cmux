#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import Security

/// A relaunched cmux takes over the Chromium Host a crashed cmux left running (task 150 of
/// plans/cmux-next/chrome-parity/p01-process.md, feature `chromiumHostSurvivesAppCrash`). The host's side, the frame
/// layout and the golden frames are in `ChromiumHost/src/host_adoption.h`; `host_adoption_test.cpp` checks the same
/// bytes as `ChromiumHostAdoptionTests`.
///
/// Chrome hands a channel only to a peer the platform vouches for (mojo's `NamedPlatformChannel`; on macOS the
/// peer's audit token and code signature, base/mac/mach_port_rendezvous.cc). So before cmux writes anything it checks
/// the process that answers on the host's socket, by the audit token of this very connection: this user's, signed by
/// this app's team, and satisfying the designated requirement of the host executable this app bundles. The host
/// checks cmux the same way. Then one offer (wire, shim ABI, fork API floor, the framework file) and one reply; on an
/// adoption the connection becomes the control channel and the remote shim takes it, as a spawned host's socket.
///
/// ``adopt()`` blocks (connect, securityd, a bounded read): call it on a lane.
nonisolated struct ChromiumHostAdoption: Sendable {
    /// The spawn argument that keeps a host's pages after cmux's crash (browser_host_main.mm, `adoption::kSwitch`).
    static let survivalArgument = "--survives-app-crash"
    static let socketName = "chromium-host.sock"
    /// macOS's `sun_path` less its NUL; a longer path takes ``shortSocketPath(rootCache:uid:)``.
    static let maxSocketPathBytes = 103
    static let adoptOp: UInt16 = 0x8020
    static let adoptReplyOp: UInt16 = 0x8021
    /// `kMinForkAPI` (chromium_host_wire.h): the oldest fork this cmux starts a host on.
    static let minForkAPI: Int32 = 30
    /// How long the host may take to answer the offer.
    static let replyLimit: Duration = .seconds(2)

    /// The framework binary a host runs, by its file: an update that replaces the framework gives it another inode,
    /// so a host started before the update is never adopted after it.
    nonisolated struct FrameworkIdentity: Equatable, Sendable {
        var device: Int64
        var inode: Int64
        var size: Int64
        var mtime: Int64

        /// `stat(2)` of `path`; nil when it cannot be read.
        static func of(_ path: String) -> FrameworkIdentity? {
            var info = stat()
            // SAFETY: stat writes one struct stat into `info`, a local, during the call.
            guard unsafe stat(path, &info) == 0 else { return nil }
            return FrameworkIdentity(device: Int64(info.st_dev), inode: Int64(info.st_ino), size: Int64(info.st_size),
                                     mtime: Int64(info.st_mtimespec.tv_sec))
        }
    }

    /// `kOpAdopt`: str wire id, str shim ABI id, i32 fork API floor, i64 framework device, inode, size, mtime, i32
    /// cmux's pid.
    nonisolated struct Offer: Equatable, Sendable {
        var wireID: String
        var abiID: String
        var minForkAPI: Int32
        var framework: FrameworkIdentity
        var appPID: Int32

        var message: ChromiumHostControlMessage {
            let values: [ChromiumHostControlMessage.Value] = [
                .str(wireID), .str(abiID), .i32(minForkAPI), .i64(framework.device), .i64(framework.inode),
                .i64(framework.size), .i64(framework.mtime), .i32(appPID),
            ]
            return ChromiumHostControlMessage(op: ChromiumHostAdoption.adoptOp, fields: values.map { .init(tag: 0, value: $0) })
        }
    }

    nonisolated enum Verdict: Int32, Equatable, Sendable {
        case adopted = 0
        case versionMismatch = 1
        case malformed = 2
    }

    /// `kOpAdoptReply`: i32 verdict, i32 host pid, i32 host fork API, i32 the first browser and DevTools ids cmux may
    /// mint, str the host's resize fence inbox ("" none).
    nonisolated struct Reply: Equatable, Sendable {
        var verdict: Verdict
        var hostPID: Int32
        var forkAPI: Int32
        var mintFloor: ChromiumHostMintFloor
        var resizeFence: String?

        /// Nil for any other frame or layout.
        init?(_ message: ChromiumHostControlMessage) {
            guard message.op == ChromiumHostAdoption.adoptReplyOp, !message.isReply, message.fds.isEmpty,
                  message.fields.count == 6,
                  case .i32(let verdict) = message.fields[0].value, let known = Verdict(rawValue: verdict),
                  case .i32(let pid) = message.fields[1].value,
                  case .i32(let forkAPI) = message.fields[2].value,
                  case .i32(let browser) = message.fields[3].value,
                  case .i32(let devtools) = message.fields[4].value,
                  case .str(let fence) = message.fields[5].value else { return nil }
            self.init(verdict: known, hostPID: pid, forkAPI: forkAPI,
                      mintFloor: ChromiumHostMintFloor(browser: browser, devtools: devtools), resizeFence: fence.isEmpty ? nil : fence)
        }

        init(verdict: Verdict, hostPID: Int32, forkAPI: Int32, mintFloor: ChromiumHostMintFloor, resizeFence: String?) {
            self.verdict = verdict
            self.hostPID = hostPID
            self.forkAPI = forkAPI
            self.mintFloor = mintFloor
            self.resizeFence = resizeFence
        }
    }

    /// What one try found.
    nonisolated enum Outcome: Equatable, Sendable {
        /// The host is this cmux's now: its pid and wire (the socket, the remote shim's from here).
        case adopted(ChromiumHostSpawn)
        /// A host runs that speaks another version: it closes its pages and quits; a new host may start once it ended.
        case versionMismatch(hostPID: pid_t)
        /// No host to adopt (no socket, nobody answers, a peer that is not this app's host): start one.
        case noHost(String)
    }

    /// The host's socket.
    let socketPath: String
    let offer: Offer
    let plan: ChromiumHostLaunchPlan
    /// Whether the process on the socket may get the offer (``trusts(_:hostExecutable:team:)``; tests pass a stand-in).
    let trusts: @Sendable (UnixSocketPeer) -> Bool

    /// The adoption of `plan`'s host, or nil when the plan names no data folder or framework file.
    init?(plan: ChromiumHostLaunchPlan, appPID: Int32 = getpid(), uid: uid_t = geteuid(),
          trusts: (@Sendable (UnixSocketPeer) -> Bool)? = nil) {
        guard let rootCache = plan.configuration.argument("root-cache"),
              let framework = plan.configuration.argument("framework"),
              let identity = FrameworkIdentity.of(framework + "/Chromium Embedded Framework") else { return nil }
        let executable = plan.configuration.executable
        let check: @Sendable (UnixSocketPeer) -> Bool = trusts ?? { peer in
            Self.trusts(peer, hostExecutable: executable, team: SigningTeamInstall.process.team)
        }
        self.init(socketPath: Self.socketPath(rootCache: rootCache, uid: uid), plan: plan,
                  offer: Offer(wireID: ChromiumHostOp.wireIdentity, abiID: ChromiumHostOp.abiIdentity, minForkAPI: Self.minForkAPI,
                               framework: identity, appPID: appPID),
                  trusts: check)
    }

    init(socketPath: String, plan: ChromiumHostLaunchPlan, offer: Offer, trusts: @escaping @Sendable (UnixSocketPeer) -> Bool) {
        self.socketPath = socketPath
        self.plan = plan
        self.offer = offer
        self.trusts = trusts
    }

    /// `<rootCache>/chromium-host.sock`, or the short path when that does not fit `sun_path`.
    static func socketPath(rootCache: String, uid: uid_t) -> String {
        var root = rootCache
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        let path = root + "/" + socketName
        return path.utf8.count <= maxSocketPathBytes ? path : shortSocketPath(rootCache: rootCache, uid: uid)
    }

    /// `/tmp/cmux-chromium-host-<uid>/<fnv1a64(rootCache)>.sock` (the host makes the directory, mode 0700).
    static func shortSocketPath(rootCache: String, uid: uid_t) -> String {
        "/tmp/cmux-chromium-host-\(uid)/\(String(format: "%016llx", fnv1a64(rootCache))).sock"
    }

    static func fnv1a64(_ text: String) -> UInt64 {
        let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        return text.utf8.reduce(offsetBasis) { ($0 ^ UInt64($1)) &* prime }
    }

    /// The host's code may get the offer: this user's process, signed by this app's team (none for an ad-hoc or
    /// unsigned build: nothing is trusted) and satisfying the designated requirement of `hostExecutable`.
    static func trusts(_ peer: UnixSocketPeer, hostExecutable: URL, team: String?) -> Bool {
        guard peer.uid == geteuid(), let team, let requirement = designatedRequirement(of: hostExecutable) else { return false }
        return peer.signed(team: team) && peer.satisfies(requirement)
    }

    /// The designated requirement of the code at `url`, as text.
    static func designatedRequirement(of url: URL) -> String? {
        var code: SecStaticCode?
        // SAFETY: SecStaticCodeCreateWithPath writes one retained SecStaticCode reference into `code`, a local.
        guard unsafe SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        // SAFETY: SecCodeCopyDesignatedRequirement writes one retained SecRequirement reference into `requirement`, a local.
        guard unsafe SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        // SAFETY: SecRequirementCopyString writes one retained CFString reference into `text`, a local.
        guard unsafe SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// One try: connect, check the peer, send the offer, read the reply. Blocks for at most ``replyLimit`` after the
    /// connect (a local connect is answered at once).
    func adopt() -> Outcome {
        let fd: Int32
        switch Self.connect(socketPath) {
        case .success(let connected): fd = connected
        case .failure(let reason): return .noHost(reason)
        }
        guard let peer = UnixSocketPeer(descriptor: fd), trusts(peer) else {
            Darwin.close(fd)
            return .noHost("the process on \(socketPath) is not this app's Chromium Host")
        }
        guard let reply = Self.exchange(offer.message, on: fd) else {
            Darwin.close(fd)
            return .noHost("the host did not answer the offer")
        }
        // The pid the reply names is the one the kernel vouched for, or the host is not believed.
        guard reply.hostPID == peer.pid else {
            Darwin.close(fd)
            return .noHost("the host's reply names another process")
        }
        switch reply.verdict {
        case .adopted:
            Self.setTimeouts(fd, .zero)  // the remote shim's channel sets its own mode
            let attachment = ChromiumHostAttachment(controlFD: fd, remoteShim: plan.remoteShim, frameworkLocales: plan.frameworkLocales,
                                                    resizeFence: reply.resizeFence, mintFloor: reply.mintFloor)
            return .adopted(ChromiumHostSpawn(pid: peer.pid, attachment: attachment, adopted: true))
        case .versionMismatch:
            Darwin.close(fd)
            return .versionMismatch(hostPID: peer.pid)
        case .malformed:
            Darwin.close(fd)
            return .noHost("the host refused the offer as malformed")
        }
    }

    /// A connected, blocking, close-on-exec socket to `path` with no SIGPIPE and ``replyLimit`` on reads and writes.
    static func connect(_ path: String) -> Result<Int32, String> {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return .failure("socket path too long") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(clamping: MemoryLayout<sockaddr_un>.size)
        // SAFETY: the view covers exactly sun_path's bytes for the closure; bytes.count is less than its size
        // (checked above), so the copy fits and leaves at least one zero byte as the path's NUL.
        unsafe withUnsafeMutableBytes(of: &address.sun_path) { unsafe $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure("socket: errno \(errno)") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        // SAFETY: setsockopt reads the one Int32 `one` holds, the length given, during the call.
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setTimeouts(fd, replyLimit)
        // SAFETY: `address` is a local sockaddr_un live for the closure; sockaddr is its common prefix (the sockets
        // API's own cast), and connect reads the whole sockaddr_un's size, the length passed.
        let connected = unsafe withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: called on a lane only (ChromiumHostLaneSpawner.adopt); a local unix socket connect
                unsafe Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let error = errno
            Darwin.close(fd)
            return .failure(error == ENOENT || error == ECONNREFUSED ? "no host waits for adoption" : "connect: errno \(error)")
        }
        return .success(fd)
    }

    static func setTimeouts(_ fd: Int32, _ limit: Duration) {
        let (seconds, attoseconds) = limit.components
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
        // SAFETY: setsockopt reads the one timeval `value` holds, the length given, during each call.
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        // SAFETY: as above.
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes `offer` and reads exactly one reply frame, no byte past it: what follows is the control stream's.
    static func exchange(_ offer: ChromiumHostControlMessage, on fd: Int32) -> Reply? {
        guard let bytes = offer.encoded(), writeAll(bytes, to: fd),
              let header = readExactly(ChromiumHostControlMessage.headerSize, from: fd) else { return nil }
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        guard length <= ChromiumHostControlMessage.maxBody, let body = readExactly(length, from: fd) else { return nil }
        var fds: [Int32] = []
        guard case .frame(let message, _) = ChromiumHostControlMessage.decode((header + body)[...], fds: &fds) else { return nil }
        return Reply(message)
    }

    private static func writeAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
        var sent = 0
        while sent < bytes.count {
            // SAFETY: write reads the bytes the buffer lends, from `sent` to its end, during the call.
            let n = unsafe bytes.withUnsafeBytes { buffer -> Int in
                guard let base = unsafe buffer.baseAddress else { return -1 }
                return unsafe Darwin.write(fd, base + sent, bytes.count - sent)
            }
            if n > 0 {
                sent += n
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private static func readExactly(_ count: Int, from fd: Int32) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            // SAFETY: read writes at most the bytes from `got` to the end of `out`, which the buffer lends for the call.
            let n = unsafe out.withUnsafeMutableBytes { buffer -> Int in
                guard let base = unsafe buffer.baseAddress else { return -1 }
                return unsafe Darwin.read(fd, base + got, count - got)
            }
            if n > 0 {
                got += n
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return nil  // EOF, the read limit or an error
            }
        }
        return out
    }
}

nonisolated extension ChromiumHostConfiguration {
    /// The value of the `--<name>=` argument, or nil.
    func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
#endif
