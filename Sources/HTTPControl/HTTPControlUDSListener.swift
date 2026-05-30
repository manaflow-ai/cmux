import Darwin
import Foundation

/// AF_UNIX HTTP listener for the cmux control transport (D12).
///
/// Mirrors the POSIX `socket(2)` / `bind(2)` / `listen(2)` pattern used
/// by the existing socket controller in ``TerminalController`` (~L1463
/// and the accept source at ~L2421). The accept loop runs on a
/// `DispatchSourceRead`; each accepted file descriptor is handed off to
/// the owning ``HTTPControlServer`` for request parsing via
/// `DispatchIO`.
///
/// Per D12 ``NWEndpoint.unix(path:)`` is intentionally avoided. The
/// socket file is created with mode `0600` so only the running user can
/// connect — the file-permission check IS the auth boundary for the
/// UDS path (the bearer token is still required, but the kernel is the
/// first line).
///
/// The listener owns no state past start/stop; it is a thin Sendable
/// adapter that calls `onAccept` for every successful `accept(2)`.
final class HTTPControlUDSListener: @unchecked Sendable {
    /// Socket path the listener bound to. Removed in ``stop()``.
    let path: String

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue
    private let onAccept: (Int32) -> Void
    private let lock = NSLock()

    /// Build a listener bound at `path`.
    ///
    /// - Parameters:
    ///   - path: Filesystem path for the AF_UNIX socket. Any existing
    ///     file at this path is unlinked at ``start()`` time.
    ///   - queue: Dispatch queue the accept handler runs on.
    ///   - onAccept: Closure invoked with each accepted client fd.
    ///     Ownership of `fd` transfers to the closure — it MUST
    ///     eventually `close()` the descriptor (the
    ///     ``HTTPControlServer`` cleanup handler does this via
    ///     `DispatchIO`).
    init(path: String, queue: DispatchQueue, onAccept: @escaping (Int32) -> Void) {
        self.path = path
        self.queue = queue
        self.onAccept = onAccept
    }

    /// Binds the socket, sets mode `0600`, and begins accepting clients.
    ///
    /// - Throws: ``HTTPControlUDSListenerError`` if any POSIX call
    ///   fails. The internal fd is closed before throwing.
    func start() throws {
        try? FileManager.default.removeItem(atPath: path)

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else {
            throw HTTPControlUDSListenerError.socketFailed(errno)
        }

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < maxLen else {
            close(s)
            throw HTTPControlUDSListenerError.pathTooLong
        }
        // Write the path bytes into sun_path FIRST, in its own pointer scope,
        // then call bind() in a separate scope — overlapping access to `addr`
        // via nested `withUnsafe…(to: &addr…)` is an exclusivity violation.
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            for (i, byte) in pathBytes.enumerated() {
                ptr.advanced(by: i).pointee = Int8(bitPattern: byte)
            }
            ptr.advanced(by: pathBytes.count).pointee = 0
        }
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else {
            let e = errno
            close(s)
            throw HTTPControlUDSListenerError.bindFailed(e)
        }
        guard listen(s, 16) == 0 else {
            let e = errno
            close(s)
            throw HTTPControlUDSListenerError.listenFailed(e)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600 as UInt16)],
                ofItemAtPath: path
            )
        } catch {
            close(s)
            throw HTTPControlUDSListenerError.chmodFailed(error)
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // Drain — kqueue may coalesce multiple accepts into one
            // wakeup, so loop until there's nothing pending.
            while true {
                var caddr = sockaddr_un()
                memset(&caddr, 0, MemoryLayout<sockaddr_un>.size)
                var clen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let cfd = withUnsafeMutablePointer(to: &caddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.fd, $0, &clen)
                    }
                }
                if cfd < 0 {
                    break
                }
                self.onAccept(cfd)
            }
        }
        src.resume()
        lock.lock()
        self.fd = s
        self.source = src
        lock.unlock()
    }

    /// Cancels the accept source, closes the listener fd, and unlinks
    /// the socket file.
    func stop() {
        lock.lock()
        let s = source
        let f = fd
        source = nil
        fd = -1
        lock.unlock()
        s?.cancel()
        if f >= 0 { close(f) }
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Failure modes for ``HTTPControlUDSListener/start()``.
enum HTTPControlUDSListenerError: Error {
    /// `socket(AF_UNIX, SOCK_STREAM, 0)` failed; payload is `errno`.
    case socketFailed(Int32)
    /// `bind(2)` failed; payload is `errno`.
    case bindFailed(Int32)
    /// `listen(2)` failed; payload is `errno`.
    case listenFailed(Int32)
    /// The requested path exceeds `sun_path` capacity (typically 104).
    case pathTooLong
    /// `setAttributes` (mode 0600) failed.
    case chmodFailed(Error)
}
