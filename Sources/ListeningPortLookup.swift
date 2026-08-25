import Darwin
import Foundation

/// What the kernel could tell us about one process's listening TCP ports.
enum ListeningPortLookupResult: Sendable, Equatable {
    /// The kernel described every descriptor this process owns.
    case ports(Set<Int>)
    /// We are not allowed to inspect this process.
    case denied
    /// The process is gone, or the kernel would not describe it.
    case unavailable
}

/// Reads listening TCP ports from the kernel with libproc.
///
/// "lsof" answers the same question, but it first calls close() on every
/// descriptor number up to "kern.maxfilesperproc" (138,240 on current macOS),
/// and it forks a child that repeats the sweep. That is far more work than the
/// lookup itself, and this scan runs every couple of seconds.
enum ListeningPortLookup {
    /// Extra descriptor slots so a process that opens files between the
    /// sizing call and the read still fits in one pass.
    private static let capacityHeadroom = 32

    static func ports(pid: pid_t) -> ListeningPortLookupResult {
        guard pid > 0 else { return .unavailable }

        errno = 0
        let sizeNeeded = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if sizeNeeded < 0 { return classify(errno) }
        if sizeNeeded == 0 { return errno == 0 ? .ports([]) : classify(errno) }

        let stride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(sizeNeeded) / stride + capacityHeadroom
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)

        errno = 0
        let written = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        if written < 0 { return classify(errno) }
        if written == 0 { return errno == 0 ? .ports([]) : classify(errno) }

        var ports: Set<Int> = []
        let usable = min(Int(written) / stride, capacity)
        for index in 0..<usable {
            let descriptor = descriptors[index]
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            if let port = listeningPort(pid: pid, fd: descriptor.proc_fd) {
                ports.insert(port)
            }
        }
        return .ports(ports)
    }

    private static func listeningPort(pid: pid_t, fd: Int32) -> Int? {
        var info = socket_fdinfo()
        let expected = Int32(MemoryLayout<socket_fdinfo>.size)
        let read = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, expected)
        // A descriptor closed mid-scan returns a short read; skip it.
        guard read == expected else { return nil }
        guard info.psi.soi_kind == SOCKINFO_TCP else { return nil }

        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }

        // "insi_lport" holds a 16-bit port in network byte order.
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
        guard port > 0, port <= 65_535 else { return nil }
        return port
    }

    private static func classify(_ code: Int32) -> ListeningPortLookupResult {
        code == EPERM || code == EACCES ? .denied : .unavailable
    }
}
