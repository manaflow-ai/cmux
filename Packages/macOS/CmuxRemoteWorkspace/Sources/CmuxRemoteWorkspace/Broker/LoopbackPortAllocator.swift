internal import Darwin

/// Finds a free `127.0.0.1` TCP port to bind a local proxy/forward listener to.
///
/// Shared by ``RemoteProxyBroker`` and the app target's
/// `RemoteTmuxBrowserProxyRegistry`, which each inject their own instance
/// rather than keeping separate allocation logic. Lives here rather than in
/// `CmuxCore` because it is infrastructure, not a value or protocol seam.
public struct LoopbackPortAllocator: Sendable {
    public init() {}

    /// Binds an ephemeral loopback TCP socket to discover a free port, then
    /// closes it. Inherently TOCTOU (the port can be taken before the caller
    /// binds it); callers should retry on bind failure rather than treat this
    /// as a reservation.
    public func allocate(attempts: Int = 8) -> Int? {
        for _ in 0..<attempts {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(0)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getsockname(fd, sockaddrPtr, &len)
                }
            }
            guard nameResult == 0 else { continue }

            let port = Int(UInt16(bigEndian: bound.sin_port))
            if port > 0 && port <= 65535 {
                return port
            }
        }
        return nil
    }
}
