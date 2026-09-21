import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Darwin
import Foundation
import Network

/// Dials out through the local `ssh -D` SOCKS5 listener ssh-tmux keeps open,
/// conforming to ``RemoteProxyStreamOpening`` so `RemoteDaemonProxySession`
/// reuses its SOCKS5/HTTP-CONNECT handshake parsing and loopback-alias HTTP
/// rewriting unchanged against this non-daemon backend — the accept side
/// (WKWebView-facing) is a `RemoteDaemonProxySession`, built via
/// `makeRemoteDaemonProxySession`, fed by ``RemoteTmuxBrowserProxyListener``;
/// this type is only the outgoing leg.
///
/// ``openStream(host:port:timeoutMs:)`` performs a bounded, nonblocking-socket
/// SOCKS5 client handshake (connect + greeting + CONNECT) rather than
/// bridging `NWConnection`'s callbacks into this synchronous `throws` API —
/// waiting on a callback from the same queue that would deliver it risks
/// deadlock, and the existing daemon-backed implementation of this protocol
/// already blocks its caller's queue for an RPC round-trip, so a bounded
/// blocking dial here preserves the same contract.
///
/// `openStreams` is guarded by `stateLock`, a plain `NSLock`, not an actor:
/// ``RemoteProxyStreamOpening`` is synchronous and non-`async` by design (see
/// above), so a caller can't `await` into actor isolation without breaking
/// that shared, production protocol.
final class RemoteTmuxSocksProxyStreamClient: RemoteProxyStreamOpening, @unchecked Sendable {
    private let localForwardPort: Int
    private let ioQueue = DispatchQueue(label: "com.cmuxterm.app.remote-tmux.browser-proxy-stream-io", qos: .userInitiated)
    private let stateLock = NSLock()
    private var openStreams: [String: DispatchIO] = [:]

    init(localForwardPort: Int) {
        self.localForwardPort = localForwardPort
    }

    func openStream(host: String, port: Int, timeoutMs: Int) throws -> String {
        let deadline = DispatchTime.now() + .milliseconds(max(timeoutMs, 0))
        let fd = try Self.connectBlocking(port: localForwardPort, deadline: deadline)
        do {
            try Self.performSocksHandshake(fd: fd, targetHost: host, targetPort: port, deadline: deadline)
        } catch {
            Darwin.close(fd)
            throw error
        }

        let streamID = UUID().uuidString
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: ioQueue) { _ in
            Darwin.close(fd)
        }
        io.setLimit(lowWater: 1)
        stateLock.lock()
        openStreams[streamID] = io
        stateLock.unlock()
        return streamID
    }

    func writeStream(streamID: String, data: Data) throws {
        guard let io = stream(for: streamID) else {
            throw RemoteTmuxError.unreachable("browser proxy stream \(streamID) is not open")
        }
        let dispatchData = data.withUnsafeBytes { DispatchData(bytes: $0) }
        // Fire-and-forget: a write failure means the peer is gone, which the
        // read side's `attachStream` event loop reports as EOF/error too.
        io.write(offset: 0, data: dispatchData, queue: ioQueue) { _, _, _ in }
    }

    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (RemoteDaemonStreamEvent) -> Void
    ) throws {
        guard let io = stream(for: streamID) else {
            throw RemoteTmuxError.unreachable("browser proxy stream \(streamID) is not open")
        }
        io.read(offset: 0, length: .max, queue: ioQueue) { done, data, error in
            if error != 0 {
                let detail = String(cString: strerror(error))
                queue.async { onEvent(.error(detail)) }
                return
            }
            let payload = data.map { Data($0) } ?? Data()
            if done {
                queue.async { onEvent(.eof(payload)) }
            } else if !payload.isEmpty {
                queue.async { onEvent(.data(payload)) }
            }
        }
    }

    func closeStream(streamID: String) {
        stateLock.lock()
        let io = openStreams.removeValue(forKey: streamID)
        stateLock.unlock()
        io?.close(flags: .stop)
    }

    private func stream(for streamID: String) -> DispatchIO? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return openStreams[streamID]
    }
}

// MARK: - Bounded, nonblocking POSIX socket helpers

extension RemoteTmuxSocksProxyStreamClient {
    private static func remainingMilliseconds(until deadline: DispatchTime) -> Int32 {
        let now = DispatchTime.now()
        guard deadline > now else { return 0 }
        let nanos = deadline.uptimeNanoseconds - now.uptimeNanoseconds
        return Int32(min(nanos / 1_000_000, UInt64(Int32.max)))
    }

    /// Opens a nonblocking TCP connection to `127.0.0.1:port`, waiting up to
    /// `deadline` via `poll(2)` rather than an unbounded blocking `connect`.
    fileprivate static func connectBlocking(port: Int, deadline: DispatchTime) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw RemoteTmuxError.launchFailed("browser proxy socket() failed: \(String(cString: strerror(errno)))")
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(bigEndian: UInt16(port))
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return fd }
        guard errno == EINPROGRESS else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw RemoteTmuxError.launchFailed("browser proxy connect() failed: \(detail)")
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let waitMs = remainingMilliseconds(until: deadline)
        guard waitMs > 0, poll(&pfd, 1, waitMs) > 0, pfd.revents & Int16(POLLOUT) != 0 else {
            close(fd)
            throw RemoteTmuxError.launchFailed("browser proxy connect() timed out")
        }

        var socketError: Int32 = 0
        var errorLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen)
        guard socketError == 0 else {
            let detail = String(cString: strerror(socketError))
            close(fd)
            throw RemoteTmuxError.launchFailed("browser proxy connect() failed: \(detail)")
        }
        return fd
    }

    /// Sends the SOCKS5 greeting + CONNECT request (reusing `SocksV5Client`'s
    /// pure, host-agnostic pieces — greeting, method-selection check, reply
    /// parsing) and validates the reply, all with bounded reads/writes
    /// against `deadline`. `fd` stays nonblocking throughout; each read/write
    /// is preceded by a `poll(2)`.
    ///
    /// Not `SocksV5Client.connectRequest`: it's IP-literal-only by design
    /// (see its type doc). ssh's `-D` forward is a real OpenSSH SOCKS5
    /// implementation that resolves a DOMAINNAME request on the remote host
    /// — the only way to reach a hostname that only exists on that side —
    /// so `connectRequest(host:port:)` below builds that address type
    /// locally rather than widening the shared type's contract for its
    /// other caller.
    fileprivate static func performSocksHandshake(
        fd: Int32,
        targetHost: String,
        targetPort: Int,
        deadline: DispatchTime
    ) throws {
        try writeAll(fd: fd, bytes: SocksV5Client.greeting, deadline: deadline)
        let methodSelection = try readExact(fd: fd, count: SocksV5Client.methodSelectionLength, deadline: deadline)
        try SocksV5Client.checkMethodSelection(methodSelection)

        let request = try connectRequest(host: targetHost, port: targetPort)
        try writeAll(fd: fd, bytes: request, deadline: deadline)

        let header = try readExact(fd: fd, count: SocksV5Client.replyHeaderLength, deadline: deadline)
        let trailerLength: Int
        if let fixed = try SocksV5Client.replyTrailerLength(header: header) {
            trailerLength = fixed
        } else {
            let lengthByte = try readExact(fd: fd, count: 1, deadline: deadline)
            trailerLength = SocksV5Client.domainReplyTrailerLength(lengthByte: lengthByte[0])
        }
        let trailer = trailerLength > 0 ? try readExact(fd: fd, count: trailerLength, deadline: deadline) : []
        try SocksV5Client.checkReply(header + trailer)
    }

    /// `VER CMD RSV ATYP DST.ADDR DST.PORT` for `host`, using SOCKS5's
    /// DOMAINNAME address type (RFC 1928 §5) when `host` isn't a literal IP —
    /// see the doc comment on `performSocksHandshake` for why this can't just
    /// reuse `SocksV5Client.connectRequest`.
    private static func connectRequest(host: String, port: Int) throws -> [UInt8] {
        guard (1...65_535).contains(port) else {
            throw RemoteTmuxError.launchFailed("browser proxy SOCKS request has an invalid port: \(host):\(port)")
        }
        var request: [UInt8] = [SocksV5Client.version, SocksV5Client.commandConnect, 0x00]
        if let ipv4 = IPv4Address(host) {
            request.append(SocksV5Client.addressTypeIPv4)
            request.append(contentsOf: ipv4.rawValue)
        } else if let ipv6 = IPv6Address(host) {
            request.append(SocksV5Client.addressTypeIPv6)
            request.append(contentsOf: ipv6.rawValue)
        } else {
            let nameBytes = Array(host.utf8)
            guard !nameBytes.isEmpty, nameBytes.count <= 255 else {
                throw RemoteTmuxError.launchFailed("browser proxy SOCKS request host is invalid: \(host)")
            }
            request.append(SocksV5Client.addressTypeDomain)
            request.append(UInt8(nameBytes.count))
            request.append(contentsOf: nameBytes)
        }
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))
        return request
    }

    private static func writeAll(fd: Int32, bytes: [UInt8], deadline: DispatchTime) throws {
        var offset = 0
        while offset < bytes.count {
            let waitMs = remainingMilliseconds(until: deadline)
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard waitMs > 0, poll(&pfd, 1, waitMs) > 0, pfd.revents & Int16(POLLOUT) != 0 else {
                throw RemoteTmuxError.launchFailed("browser proxy SOCKS handshake write timed out")
            }
            let written = bytes[offset...].withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress, ptr.count)
            }
            guard written > 0 else {
                throw RemoteTmuxError.launchFailed("browser proxy SOCKS handshake write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }

    private static func readExact(fd: Int32, count: Int, deadline: DispatchTime) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let waitMs = remainingMilliseconds(until: deadline)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard waitMs > 0, poll(&pfd, 1, waitMs) > 0, pfd.revents & Int16(POLLIN) != 0 else {
                throw RemoteTmuxError.launchFailed("browser proxy SOCKS handshake read timed out")
            }
            let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            guard bytesRead > 0 else {
                throw RemoteTmuxError.launchFailed("browser proxy SOCKS handshake connection closed")
            }
            offset += bytesRead
        }
        return buffer
    }
}
