#if canImport(Darwin)
package import Darwin
#elseif canImport(Glibc)
package import Glibc
#endif

/// The `sockaddr_un` of a Unix-domain socket path, filled in one place, and the one place that hands it to the
/// kernel as a `sockaddr`. Chromium fills its Unix addresses in one helper too (`FillUnixAddress`,
/// net/base/sockaddr_util_posix.cc); the daemon connection, the control socket's bind and probe and the control
/// peer client share this one instead of each copying bytes into `sun_path`, and a seam that stands in for
/// `bind(2)` takes this value, not a raw `sockaddr` pointer.
package struct UnixSocketAddress: Sendable {
    /// The bytes of `sun_path`, the path's terminating NUL included (104 on Darwin, 108 on Linux).
    package static let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// The path the address names.
    package let path: String
    private let storage: sockaddr_un

    /// The address of `path`; nil when the path and its NUL do not fit `sun_path`.
    package init?(path: String) {
        let bytes = Array(path.utf8)
        guard bytes.count < Self.pathCapacity else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        // Only the BSD address carries its own length; Linux's sockaddr_un has no sun_len.
        address.sun_len = UInt8(clamping: MemoryLayout<sockaddr_un>.size)
        #endif
        // SAFETY: the view covers exactly sun_path's pathCapacity bytes and lives only for the closure;
        // bytes.count < pathCapacity (checked above), so the copy fits and leaves at least the last byte, which
        // sockaddr_un() zero-filled, as the path's NUL.
        unsafe withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
            unsafe sunPath.copyBytes(from: bytes)
        }
        self.path = path
        storage = address
    }

    /// Calls `body` with the address as a `sockaddr` and its length, for `bind(2)` or `connect(2)`. The pointer
    /// is valid only during the call.
    package func withSockaddr<Result>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        var address = storage
        // SAFETY: `address` is a local sockaddr_un live for the closure; sockaddr is its common prefix (the
        // sockets API's own cast), and the length passed with it is the whole sockaddr_un's size.
        return unsafe withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                unsafe body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Connects `descriptor` to the address: what `connect(2)` returns (0, or -1 with `errno` set).
    package func connect(_ descriptor: Int32) -> Int32 {
        // SAFETY: connect reads the given length of the address withSockaddr lends for the call.
        unsafe withSockaddr { unsafe systemConnect(descriptor, $0, $1) }
    }

    /// Binds `descriptor` to the address: what `bind(2)` returns (0, or -1 with `errno` set).
    package func bind(_ descriptor: Int32) -> Int32 {
        // SAFETY: bind reads the given length of the address withSockaddr lends for the call.
        unsafe withSockaddr { unsafe systemBind(descriptor, $0, $1) }
    }
}

/// `connect(2)` under a name that ``UnixSocketAddress/connect(_:)`` does not hide. The C library's module is
/// Darwin on Apple platforms and Glibc on Linux, so the method cannot qualify the call with it.
private func systemConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    // SAFETY: passes on the caller's address and its length unchanged; connect reads them only during the call.
    unsafe connect(descriptor, address, length)
}

/// `bind(2)` under a name that ``UnixSocketAddress/bind(_:)`` does not hide (see `systemConnect`).
private func systemBind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    // SAFETY: passes on the caller's address and its length unchanged; bind reads them only during the call.
    unsafe bind(descriptor, address, length)
}
