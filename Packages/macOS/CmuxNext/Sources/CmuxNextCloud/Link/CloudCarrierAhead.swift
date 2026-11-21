import Foundation

/// One open connection on a `carrier serve` socket that carries nothing. The serve dials the machine for its first
/// accepted connection and keeps that session while a connection rides it (cmux-tui `carrier/held.rs`), so holding
/// this one keeps a session that was dialed ahead (``CloudCarrierServe/dialAhead(limit:keep:)``). Closed when dropped.
final class CloudCarrierAhead: Sendable {
    private let descriptor: Int32

    /// Connects to the Unix socket at `path`; nil when the path does not fit an address or nothing accepts there.
    init?(path: String) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // One byte is left for the terminating zero the zeroed address already holds.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        // Nothing is ever written to it; set all the same, so no later write could raise SIGPIPE.
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}
