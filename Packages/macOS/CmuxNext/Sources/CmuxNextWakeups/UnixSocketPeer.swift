#if canImport(Darwin)
import Darwin
import Security
#elseif os(Linux)
import CmuxNextCompat
public import Glibc
#endif
public import Foundation

/// The process at the other end of a connected unix socket, read on that very descriptor
/// (cx-fcaq, cx-l2ai). A caller that sends a secret checks the connection it writes on, never
/// a probe connection: a same-uid process could take the socket path between the two.
///
/// Darwin:
/// - `uid`: `LOCAL_PEERCRED`;
/// - `pid` and `executablePath`: `LOCAL_PEERPID`, then `proc_pidpath` with symlinks resolved;
/// - the code-signing checks use the peer's audit token (`LOCAL_PEERTOKEN`), not its pid, so a
///   reused pid cannot stand in for it.
///
/// Linux (as Chromium reads a peer, `SO_PEERCRED` in ipc/unix_domain_socket_util.cc):
/// - `uid` and `pid`: `SO_PEERCRED`, taken by the kernel at connect;
/// - `executablePath`: `/proc/<pid>/exe`, kept only while the peer's `SO_PEERPIDFD` (Linux 6.5) says
///   that process still runs, so a reused pid cannot stand in for it. Only a kernel without the option
///   (ENOPROTOOPT) reads the path alone; any other refusal (EINVAL for a reaped peer on 6.5 to 6.15) is no peer;
/// - no code signature exists, so ``satisfies(_:)`` and ``signed(team:identifier:)`` are false.
public nonisolated struct UnixSocketPeer: Sendable {
    public let pid: pid_t
    public let uid: uid_t
    /// The peer executable's path, symlinks resolved.
    public let executablePath: String
    #if canImport(Darwin)
    private let auditToken: Data

    /// `LOCAL_PEERTOKEN` (sys/un.h).
    private static let localPeerToken: Int32 = 0x006

    /// Nil when any of the peer's facts cannot be read.
    public init?(descriptor: Int32) {
        var credentials = xucred()
        var credentialsSize = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsSize) == 0,
              credentials.cr_version == XUCRED_VERSION else { return nil }
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0, pid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, Self.localPeerToken, &token, &tokenSize) == 0 else { return nil }
        self.pid = pid
        uid = credentials.cr_uid
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        executablePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        auditToken = withUnsafeBytes(of: &token) { Data($0) }
    }
    #elseif os(Linux)
    /// `SO_PEERPIDFD` (Linux 6.5, asm-generic/socket.h); an older kernel refuses it (ENOPROTOOPT).
    private static let peerPidfdOption: Int32 = 77

    /// Nil when any of the peer's facts cannot be read, or the peer exited while they were read.
    public init?(descriptor: Int32) {
        self.init(descriptor: descriptor, peerProcess: Self.peerProcess)
    }

    /// The same, with the `SO_PEERPIDFD` read injected (tests give it the answers of other kernels).
    init?(descriptor: Int32, peerProcess: (Int32) -> PeerProcess?) {
        // struct ucred { pid_t pid; uid_t uid; gid_t gid; } (socket(7)), three 32-bit words; glibc declares the
        // struct only under _GNU_SOURCE, which its Swift module is built without.
        var credentials: [UInt32] = [0, 0, 0]
        var size = socklen_t(credentials.count * MemoryLayout<UInt32>.size)
        // SAFETY: getsockopt writes at most `size` bytes, the array's 12, into `credentials`, live for the call.
        guard unsafe getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0,
              size == socklen_t(credentials.count * MemoryLayout<UInt32>.size) else { return nil }
        let pid = pid_t(bitPattern: credentials[0])
        guard pid > 1, let process = peerProcess(descriptor) else { return nil }
        defer { process.close() }
        // The path first, then the liveness: a peer still running after the read had not given its pid away.
        guard let link = try? FileManager.checked.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe"),
              !process.hasExited else { return nil }
        self.pid = pid
        uid = credentials[1]
        executablePath = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
    }

    /// What `SO_PEERPIDFD` says of the peer.
    enum PeerProcess: Equatable {
        /// The peer's pidfd, which this value owns.
        case pidfd(Int32)
        /// The kernel has no `SO_PEERPIDFD` (before Linux 6.5), so only the path can be read.
        case noOption

        /// The answer of `getsockopt(SO_PEERPIDFD)`: its `result`, the `pidfd` it wrote and the `error` it left.
        /// Nil when the kernel has the option and refused it: on Linux 6.5 to 6.15, pidfd_prepare gives EINVAL
        /// for a reaped peer, whose pid may already be another process's.
        init?(result: Int32, pidfd: Int32, error: Int32) {
            if result == 0 {
                self = .pidfd(pidfd)
            } else if error == ENOPROTOOPT {
                self = .noOption
            } else {
                return nil
            }
        }

        /// Whether the process has exited: a pidfd turns readable at its exit (pidfd_open(2)).
        var hasExited: Bool {
            guard case let .pidfd(pidfd) = self else { return false }
            var entry = pollfd(fd: pidfd, events: Int16(truncatingIfNeeded: POLLIN), revents: 0)
            // SAFETY: poll reads and writes one pollfd, the count given, in `entry`, a local live for the call;
            // the 0 timeout returns at once.
            return unsafe poll(&entry, 1, 0) != 0
        }

        /// Closes the pidfd, if there is one.
        func close() {
            if case let .pidfd(pidfd) = self { _ = Glibc.close(pidfd) }
        }
    }

    /// Reads the peer's `SO_PEERPIDFD`.
    private static func peerProcess(_ descriptor: Int32) -> PeerProcess? {
        var pidfd: Int32 = -1
        var size = socklen_t(MemoryLayout<Int32>.size)
        // SAFETY: getsockopt writes at most `size` bytes, one Int32, into `pidfd`, a local live for the call.
        let result = unsafe getsockopt(descriptor, SOL_SOCKET, peerPidfdOption, &pidfd, &size)
        return PeerProcess(result: result, pidfd: pidfd, error: result == 0 ? 0 : errno)
    }
    #endif

    /// Whether the peer runs `executable` (symlinks resolved on both sides).
    public func runs(_ executable: URL) -> Bool {
        executablePath == executable.resolvingSymlinksInPath().path
    }

    /// Whether the peer's code, named by its audit token, satisfies the code requirement `text`.
    /// Always false on Linux, where no code signature exists.
    public func satisfies(_ text: String) -> Bool {
        #if canImport(Darwin)
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken] as CFDictionary, [], &code)
                == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        #else
        false
        #endif
    }

    /// Apple-anchored and signed by `team`, with exactly `identifier` when one is given.
    public func signed(team: String, identifier: String? = nil) -> Bool {
        let plain = { (text: String) in
            !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        }
        guard plain(team), identifier.map(plain) ?? true else { return false }
        var text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        if let identifier { text = "identifier \"\(identifier)\" and " + text }
        return satisfies(text)
    }
}
