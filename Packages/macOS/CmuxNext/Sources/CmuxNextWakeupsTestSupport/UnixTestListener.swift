import CmuxNextCompat
import Darwin
import Foundation

/// A listening Unix stream socket in the temporary directory for a client under test. A connect completes in
/// the listen backlog, so a client is ready, and can send, before the test accepts it; ``accept()`` then
/// returns at once and gives the test the server end to read from or write to.
///
/// ```swift
/// let listener = try UnixTestListener()
/// defer { listener.close() }
/// let lane = try await UnixSocketLane.connect(path: listener.path)
/// let server = try listener.accept()
/// ```
public nonisolated final class UnixTestListener: Sendable {
    /// The socket's path (it is unlinked by ``close()``).
    public let path: String
    private let descriptor: Int32

    /// Binds and listens on a fresh path.
    public init() throws {
        let path = NSTemporaryDirectory() + "lane-\(UUID().uuidString.prefix(8)).sock"
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        Self.noSigpipe(descriptor)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        // SAFETY: copies at most the path field's size less its NUL into the local `address`, live for the call.
        unsafe withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            unsafe buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        // SAFETY: `bind` reads one `sockaddr_un` from the local `address` during the call.
        let bound = unsafe withUnsafePointer(to: &address) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        self.path = path
        self.descriptor = descriptor
    }

    /// The server end of the next connection (no SIGPIPE on a write after the client left), waiting for one
    /// when none is in the backlog. Call it after the client connected (it blocks the caller until then).
    public func accept() throws -> Int32 {
        // SAFETY: no address is written (both pointers are nil).
        let client = unsafe Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { throw POSIXError(.ECONNABORTED) }
        Self.noSigpipe(client)
        return client
    }

    /// Stops listening and removes the path.
    public func close() {
        Darwin.close(descriptor)
        _ = blockingCall(.fileIO) { unlink(path) }
    }

    private static func noSigpipe(_ descriptor: Int32) {
        var on: Int32 = 1
        // SAFETY: `setsockopt` reads one Int32 from the local `on` during the call.
        _ = unsafe setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}
