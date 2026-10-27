#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads who is at the other end of an accepted control connection, from that connection's descriptor:
/// the kernel took the facts when the client connected, so a client cannot claim another's. Darwin:
/// `getpeereid` and `LOCAL_PEERPID`; Linux: `SO_PEERCRED`. Chromium reads a socket peer the same way
/// (ipc/unix_domain_socket_util.cc, `GetPeerEuid`: `getpeereid` on macOS, `SO_PEERCRED` on Linux).
///
/// A fact the call cannot read stays nil, and ``ControlAuthorizer`` admits no peer whose uid (or, for
/// `cmuxOnly`, pid) is unknown. Injected into ``ControlSocketServer`` so tests can present any peer.
struct ControlPeerCredentials: Sendable {
    var read: @Sendable (_ descriptor: Int32) -> ControlSocketServer.Peer

    #if canImport(Darwin)
    static let system = ControlPeerCredentials { descriptor in
        var uid: uid_t = 0
        var gid: gid_t = 0
        // SAFETY: getpeereid writes one uid_t and one gid_t into the locals `uid` and `gid`, live for the call.
        let hasUID = unsafe getpeereid(descriptor, &uid, &gid) == 0
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // SAFETY: getsockopt writes at most `length` bytes (the size of pid_t) into the local `pid` and the size it
        // wrote into `length`.
        let hasPID = unsafe getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0
        return ControlSocketServer.Peer(pid: hasPID ? pid : nil, uid: hasUID ? uid : nil)
    }
    #else
    static let system = ControlPeerCredentials { descriptor in
        // struct ucred { pid_t pid; uid_t uid; gid_t gid; } (socket(7)): three 32-bit words. Glibc declares the
        // struct only under _GNU_SOURCE, which its Swift module is built without.
        var credentials: [UInt32] = [0, 0, 0]
        let expected = socklen_t(credentials.count * MemoryLayout<UInt32>.size)
        var size = expected
        // SAFETY: getsockopt writes at most `size` bytes, the array's 12, into its own storage, lent for the call.
        guard unsafe getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0, size == expected else {
            return ControlSocketServer.Peer(pid: nil, uid: nil)
        }
        // A peer with no process (a socket passed out of a pid namespace) reads pid 0: unknown.
        let pid = pid_t(bitPattern: credentials[0])
        return ControlSocketServer.Peer(pid: pid > 0 ? pid : nil, uid: credentials[1])
    }
    #endif
}

extension ControlSocketServer {
    /// The client's facts ``ControlPeerCredentials`` read; nil where it could not.
    struct Peer: Sendable {
        var pid: pid_t?
        var uid: uid_t?
    }
}
