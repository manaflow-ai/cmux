import Darwin
import Foundation

/// Allocates a free TCP port on loopback for a managed Chromium child.
struct ChromiumLoopbackPortAllocator: Sendable {
    /// Allocates an ephemeral loopback port.
    func allocate() async throws -> Int {
        try bindAndRelease(preferredPort: nil)
    }

    /// Verifies that a requested positive port is currently bindable on
    /// loopback. Chromium still performs the authoritative bind immediately
    /// afterward; this preflight turns common collisions into a useful error.
    func validate(_ port: Int) async throws -> Int {
        guard ChromiumRemoteDebuggingPort(rawValue: port)?.isExternallyAttachable == true else {
            throw CDPError.invalidEndpoint
        }
        return try bindAndRelease(preferredPort: port)
    }

    /// POSIX socket creation and binding are immediate syscalls, not blocking
    /// network I/O. Binding the exact loopback address guarantees the probe can
    /// never advertise or reserve a non-loopback interface.
    private func bindAndRelease(preferredPort: Int?) throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CDPError.disconnected(Self.posixErrorDescription(errno))
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(preferredPort ?? 0).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr(ChromiumLaunchArguments.loopbackAddress))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            let code = errno
            if let preferredPort, code == EADDRINUSE || code == EACCES || code == EPERM {
                throw CDPError.portUnavailable(preferredPort)
            }
            throw CDPError.disconnected(Self.posixErrorDescription(code))
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            throw CDPError.disconnected(Self.posixErrorDescription(errno))
        }

        let port = Int(UInt16(bigEndian: boundAddress.sin_port))
        guard ChromiumRemoteDebuggingPort(rawValue: port)?.isExternallyAttachable == true else {
            throw CDPError.invalidEndpoint
        }
        return port
    }

    private static func posixErrorDescription(_ code: Int32) -> String {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    }
}
