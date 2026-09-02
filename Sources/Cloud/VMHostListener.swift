import Darwin
import Foundation
import os

/// A TCP listener bound to specific local addresses — the Mac's own
/// addresses on its WireGuard tunnel into the private Cloud VM network.
///
/// Binding to those exact addresses (never `0.0.0.0`) means the port exists
/// only while the tunnel does: when the utun goes away the sockets fail
/// closed, and nothing on the LAN or loopback can reach the listener at all.
/// Accepted descriptors are handed to `onAccept` together with the peer's
/// numeric address; the caller owns the descriptor from then on.
final class VMHostListener: @unchecked Sendable {
    struct BoundAddress: Sendable, Equatable {
        let address: String
        let port: UInt16
    }

    enum ListenerError: Error, CustomStringConvertible {
        case unsupportedAddress(String)
        case socketFailed(String, Int32)
        case bindFailed(String, Int32)
        case listenFailed(String, Int32)

        var description: String {
            switch self {
            case .unsupportedAddress(let address): return "unsupported listener address \(address)"
            case .socketFailed(let address, let code): return "socket(\(address)) failed: \(String(cString: strerror(code)))"
            case .bindFailed(let address, let code): return "bind(\(address)) failed: \(String(cString: strerror(code)))"
            case .listenFailed(let address, let code): return "listen(\(address)) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    private struct Bound {
        let socket: Int32
        let source: DispatchSourceRead
        let address: BoundAddress
    }

    private let queue = DispatchQueue(label: "dev.cmux.vm-host-listener", qos: .utility)
    private let state = OSAllocatedUnfairLock<[Bound]>(initialState: [])
    private let onAccept: @Sendable (_ socket: Int32, _ peerAddress: String) -> Void

    init(onAccept: @escaping @Sendable (_ socket: Int32, _ peerAddress: String) -> Void) {
        self.onAccept = onAccept
    }

    deinit { stop() }

    var boundAddresses: [BoundAddress] {
        state.withLock { $0.map(\.address) }
    }

    var isListening: Bool {
        state.withLock { !$0.isEmpty }
    }

    /// Bind and listen on every address. `port` 0 lets the kernel pick a port
    /// on the first address, which is then reused for the rest so one port
    /// number describes the listener. Throws (and binds nothing) if any
    /// address fails.
    func start(addresses: [String], port requestedPort: UInt16) throws {
        stop()
        // Bind everything first so a failure binds nothing and no dispatch
        // source is ever created for a descriptor that will be closed (a
        // suspended source must not be released).
        var sockets: [(fd: Int32, address: BoundAddress)] = []
        var port = requestedPort
        do {
            for address in addresses {
                let socketFD = try Self.listen(address: address, port: port)
                let actualPort = try Self.localPort(of: socketFD, address: address)
                if port == 0 { port = actualPort }
                sockets.append((socketFD, BoundAddress(address: address, port: actualPort)))
            }
        } catch {
            for entry in sockets { close(entry.fd) }
            throw error
        }
        var bound: [Bound] = []
        for entry in sockets {
            let socketFD = entry.fd
            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
            source.setEventHandler { [weak self] in
                self?.drainAccepts(listener: socketFD)
            }
            source.setCancelHandler {
                close(socketFD)
            }
            bound.append(Bound(socket: socketFD, source: source, address: entry.address))
        }
        state.withLock { $0 = bound }
        for entry in bound { entry.source.resume() }
    }

    func stop() {
        let bound = state.withLock { current -> [Bound] in
            let snapshot = current
            current = []
            return snapshot
        }
        // Cancel closes the descriptor (cancel handler); a source that never
        // resumed must be resumed first or it is leaked.
        for entry in bound { entry.source.cancel() }
    }

    // MARK: - internals

    private func drainAccepts(listener: Int32) {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &length) }
            }
            guard client >= 0 else {
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                return // EAGAIN or a fatal error; the read source fires again when ready
            }
            // Accepted sockets inherit O_NONBLOCK on macOS; the async line
            // reader expects a blocking descriptor like the Unix socket path.
            let flags = fcntl(client, F_GETFL)
            if flags >= 0 { _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK) }
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let peer = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Self.numericAddress($0) }
            } ?? ""
            onAccept(client, peer)
        }
    }

    private static func listen(address: String, port: UInt16) throws -> Int32 {
        guard let bytes = VMHostAccessPolicy.addressBytes(address) else {
            throw ListenerError.unsupportedAddress(address)
        }
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.socketFailed(address, errno) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let bindResult: Int32
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            _ = inet_pton(AF_INET, address, &addr.sin_addr)
            bindResult = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            var text = address
            if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
            _ = inet_pton(AF_INET6, text, &addr.sin6_addr)
            var v6Only: Int32 = 1
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
            bindResult = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw ListenerError.bindFailed(address, code)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw ListenerError.listenFailed(address, code)
        }
        return fd
    }

    private static func localPort(of fd: Int32, address: String) throws -> UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw ListenerError.bindFailed(address, errno) }
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
        case AF_INET6:
            return withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
        default:
            throw ListenerError.unsupportedAddress(address)
        }
    }

    static func numericAddress(_ sa: UnsafePointer<sockaddr>) -> String? {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        case AF_INET6:
            var addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer).lowercased()
        default:
            return nil
        }
    }
}
