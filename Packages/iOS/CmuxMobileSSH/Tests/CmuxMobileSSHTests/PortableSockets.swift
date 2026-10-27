#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The few socket spellings that differ between Darwin and Glibc, for the
// tests' blocking loopback clients and servers.

#if canImport(Darwin)
/// `SOCK_STREAM` as `socket(2)` takes it.
let streamSocketType = SOCK_STREAM
#else
/// `SOCK_STREAM` as `socket(2)` takes it (Glibc spells it as an enum case).
let streamSocketType = Int32(SOCK_STREAM.rawValue)
#endif

/// `connect(2)`, for callers inside a type with its own `connect`.
func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.connect(fd, address, length)
    #else
    Glibc.connect(fd, address, length)
    #endif
}

/// `close(2)`, for callers inside a type with its own `close`.
func systemClose(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}
