import Dispatch
import Foundation

/// One inbound connection accepted by ``MobileHostPOSIXListener``.
///
/// The file descriptor is a connected, nonblocking TCP socket with
/// `TCP_NODELAY` and `SO_NOSIGPIPE` already applied. The receiver owns the
/// descriptor and must close it (usually by wrapping it in a transport that
/// closes on teardown).
struct MobileHostPOSIXAcceptedConnection: Sendable {
    let fileDescriptor: Int32
    let peerIsLoopback: Bool
}

/// BSD-socket TCP listener for the legacy mobile pairing host.
///
/// Replaces the previous Network.framework `NWListener`: on macOS 26/27 with
/// the Tailscale system extension active, inbound-delivered connections whose
/// listener socket is an NWListener socket are dropped by NECP policy before
/// `accept` runs, so an iOS client dialing the Mac's Tailscale address can
/// never reach the host. A POSIX listening socket receives those same
/// connections (verified side by side on macOS 27.0 + Tailscale 1.103.85:
/// identical NWListener and BSD listeners on this Mac, NW unreachable via the
/// Tailscale address, BSD accepting).
///
/// The listener binds an IPv6 dual-stack wildcard (`[::]` with
/// `IPV6_V6ONLY=0`, mirroring the old `tcp6 *.<port>` shape), so IPv4 and
/// IPv6 clients both reach it. `bind` and `listen` complete synchronously in
/// ``init(preferredPort:queue:)``, so a successfully constructed listener is
/// already accepting into its backlog; ``start(onAccepted:onCancelled:)``
/// only arms the event handler that drains accepted sockets.
///
/// All mutable state is confined to `queue` (the DispatchSource event queue,
/// the sanctioned carve-out for low-level socket I/O), which is what makes the
/// class `@unchecked Sendable`: `init` finishes before the instance escapes,
/// and every later mutation happens on `queue`.
final class MobileHostPOSIXListener: @unchecked Sendable {
    enum ListenerError: Error, Equatable, Sendable {
        case socketCreationFailed(Int32)
        case optionFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }

    private let queue: DispatchQueue
    private let fileDescriptor: Int32
    private let source: any DispatchSourceRead
    private var onAccepted: ((MobileHostPOSIXAcceptedConnection) -> Void)?
    private var onCancelled: (() -> Void)?
    private var didCancel = false
    /// The bound port, resolved from the kernel (ephemeral when
    /// `preferredPort` is nil or 0). Immutable after init.
    let boundPort: UInt16

    /// Binds and listens immediately.
    ///
    /// - Parameters:
    ///   - preferredPort: The port to bind, or nil for an OS-assigned
    ///     ephemeral port. Binding a busy port throws
    ///     ``ListenerError/bindFailed`` with `EADDRINUSE`.
    ///   - queue: The dispatch queue that receives accepted connections and
    ///     the cancellation callback. The service passes the shared
    ///     `dev.cmux.mobile.host-listener` queue.
    /// - Throws: ``ListenerError`` when the socket cannot be created, bound,
    ///   or switched to listening.
    init(preferredPort: UInt16?, queue: DispatchQueue) throws {
        self.queue = queue
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ListenerError.socketCreationFailed(errno)
        }
        fileDescriptor = fd

        do {
            var yes: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw ListenerError.optionFailed(errno)
            }
            var no: Int32 = 0
            guard setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw ListenerError.optionFailed(errno)
            }

            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = (preferredPort ?? 0).bigEndian
            address.sin6_addr = in6addr_any
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard bindResult == 0 else {
                throw ListenerError.bindFailed(errno)
            }
            guard listen(fd, 128) == 0 else {
                throw ListenerError.listenFailed(errno)
            }

            var bound = sockaddr_in6()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &boundLength)
                }
            }
            guard nameResult == 0 else {
                throw ListenerError.bindFailed(errno)
            }
            boundPort = bound.sin6_port.bigEndian
        } catch {
            close(fd)
            throw error
        }

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.closeFileDescriptor()
            self.onCancelled?()
            self.onCancelled = nil
        }
        source.resume()
    }

    /// Arms the accept callback. Idempotent: the latest handlers win.
    ///
    /// - Parameters:
    ///   - onAccepted: Invoked on `queue` once per accepted connection. The
    ///     receiver owns the handed-off file descriptor.
    ///   - onCancelled: Invoked on `queue` when the listener stops for any
    ///     reason other than an intentional ``disarm()`` followed by
    ///     ``cancel()``.
    func start(
        onAccepted: @escaping (MobileHostPOSIXAcceptedConnection) -> Void,
        onCancelled: @escaping () -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.didCancel else { return }
            self.onAccepted = onAccepted
            self.onCancelled = onCancelled
        }
    }

    /// Clears the callbacks so a subsequent ``cancel()`` stays silent.
    ///
    /// Intentional teardown paths (settings stop, port change, adoption of a
    /// replacement listener) call this before ``cancel()``; spontaneous
    /// cancellation keeps its callback.
    func disarm() {
        queue.async { [weak self] in
            guard let self else { return }
            self.onAccepted = nil
            self.onCancelled = nil
        }
    }

    /// Stops listening and releases the bound port. Safe to call twice.
    func cancel() {
        queue.async { [weak self] in
            guard let self, !self.didCancel else { return }
            self.didCancel = true
            self.source.cancel()
        }
    }

    /// Whether `address` is a loopback peer: IPv4 `127.0.0.0/8`, IPv6 `::1`,
    /// or an IPv4-mapped loopback address carried in an IPv6 sockaddr.
    ///
    /// Release builds reject loopback peers on the legacy listener (a real
    /// phone always arrives over a network interface), so this classification
    /// must match the old `NWEndpoint`-based check exactly.
    static func isLoopbackPeer(_ address: sockaddr_storage) -> Bool {
        switch Int32(address.ss_family) {
        case AF_INET:
            return withUnsafeBytes(of: address) { raw in
                guard raw.count >= MemoryLayout<sockaddr_in>.size else { return false }
                let sin = raw.loadUnaligned(as: sockaddr_in.self)
                return (sin.sin_addr.s_addr.bigEndian & 0xFF00_0000) == 0x7F00_0000
            }
        case AF_INET6:
            return withUnsafeBytes(of: address) { raw in
                guard raw.count >= MemoryLayout<sockaddr_in6>.size else { return false }
                let sin6 = raw.loadUnaligned(as: sockaddr_in6.self)
                let bytes = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
                // ::1
                if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
                    return true
                }
                // ::ffff:127.0.0.0/8 (IPv4-mapped)
                if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF,
                   bytes[12] == 127 {
                    return true
                }
                return false
            }
        default:
            return false
        }
    }

    // MARK: - Private

    /// Runs on `queue`: drains every pending connection, then returns; the
    /// nonblocking listener socket makes `accept` return `EAGAIN` when the
    /// backlog is empty, which ends the drain without blocking the queue.
    private func acceptPendingConnections() {
        guard let onAccepted else { return }
        while true {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fileDescriptor, $0, &peerLength)
                }
            }
            guard client >= 0 else {
                return
            }
            configure(client)
            onAccepted(
                MobileHostPOSIXAcceptedConnection(
                    fileDescriptor: client,
                    peerIsLoopback: Self.isLoopbackPeer(peer)
                )
            )
        }
    }

    /// Applies the socket options every accepted connection needs:
    /// nonblocking for the dispatch-source event loop, `TCP_NODELAY` to match
    /// the interactive RPC latency of the old NW listener, and `SO_NOSIGPIPE`
    /// so a peer reset surfaces as an error instead of a fatal signal.
    private func configure(_ client: Int32) {
        let flags = fcntl(client, F_GETFL)
        if flags >= 0 {
            _ = fcntl(client, F_SETFL, flags | O_NONBLOCK)
        }
        var yes: Int32 = 1
        _ = setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private func closeFileDescriptor() {
        close(fileDescriptor)
    }
}
