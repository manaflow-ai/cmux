public import Foundation
public import CmuxWireGuardPairing
import CmuxWGC
import os

/// One userspace WireGuard device with its own TCP/IP stack (libcmuxwg).
///
/// It needs no system VPN: WireGuard datagrams go out on an ordinary UDP
/// socket and tunneled TCP connections surface as `SocketStream`s. Blocking
/// library calls (accept, dial) run on a private queue, never on the caller.
public final class WireGuardTunnel: Sendable {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case library(operation: String, code: Int32)
        case stopped

        public var errorDescription: String? {
            switch self {
            case .library(let operation, let code):
                "WireGuard \(operation) failed (\(String(cString: strerror(code))))"
            case .stopped: "The WireGuard tunnel stopped."
            }
        }
    }

    /// One WireGuard peer in UAPI terms.
    public struct Peer: Hashable, Sendable {
        public var publicKey: WireGuardKey
        public var presharedKey: WireGuardKey?
        public var endpoint: String?
        public var allowedIPs: [String]
        public var keepaliveSeconds: Int?

        public init(publicKey: WireGuardKey, presharedKey: WireGuardKey? = nil, endpoint: String? = nil,
                    allowedIPs: [String], keepaliveSeconds: Int? = nil) {
            self.publicKey = publicKey
            self.presharedKey = presharedKey
            self.endpoint = endpoint
            self.allowedIPs = allowedIPs
            self.keepaliveSeconds = keepaliveSeconds
        }

        var uapi: String {
            var lines = ["public_key=\(publicKey.hex)"]
            if let presharedKey { lines.append("preshared_key=\(presharedKey.hex)") }
            if let endpoint { lines.append("endpoint=\(endpoint)") }
            lines.append("replace_allowed_ips=true")
            lines += allowedIPs.map { "allowed_ip=\($0)" }
            if let keepaliveSeconds { lines.append("persistent_keepalive_interval=\(keepaliveSeconds)") }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    public let address: String
    private let handle: Int64
    private let blocking = DispatchQueue(label: "cmux.wireguard.blocking", attributes: .concurrent)
    private let state = OSAllocatedUnfairLock(initialState: false)

    /// Starts a device at `address` with `privateKey`. `listenPort` 0 picks
    /// a free port (read it back from `status().listenPort`).
    public init(address: String, privateKey: WireGuardKey, listenPort: UInt16 = 0, peers: [Peer] = [], mtu: Int32 = 1280) throws {
        WireGuardLog.install()
        var config = "private_key=\(privateKey.hex)\nlisten_port=\(listenPort)\n"
        config += peers.map(\.uapi).joined()
        let handle = mutableCString(address) { address in mutableCString(config) { cmuxwg_start(address, $0, mtu) } }
        guard handle > 0 else { throw Failure.library(operation: "start", code: Int32(-handle)) }
        self.handle = handle
        self.address = address
    }

    deinit { stop() }

    /// Adds or replaces a peer.
    public func setPeer(_ peer: Peer) throws {
        try apply(peer.uapi)
    }

    /// Removes a peer; its open connections stall and time out.
    public func removePeer(_ publicKey: WireGuardKey) throws {
        try apply("public_key=\(publicKey.hex)\nremove=true\n")
    }

    /// Points a peer at a new endpoint (the phone trying the next address).
    public func setEndpoint(_ endpoint: String, for publicKey: WireGuardKey) throws {
        try apply("public_key=\(publicKey.hex)\nupdate_only=true\nendpoint=\(endpoint)\n")
    }

    private func apply(_ uapi: String) throws {
        let code = mutableCString(uapi) { cmuxwg_set(handle, $0) }
        guard code == 0 else { throw Failure.library(operation: "configure", code: -code) }
    }

    /// The device's live state.
    public func status() -> WireGuardStatus {
        guard let raw = cmuxwg_get(handle) else { return WireGuardStatus(uapi: "") }
        defer { cmuxwg_free(raw) }
        return WireGuardStatus(uapi: String(cString: raw))
    }

    /// Reopens the UDP socket after the network changed.
    public func rebind() {
        _ = cmuxwg_rebind(handle)
    }

    /// Stops the device. Idempotent; open streams see end of stream.
    public func stop() {
        let first = state.withLock { stopped -> Bool in
            defer { stopped = true }
            return !stopped
        }
        if first { cmuxwg_stop(handle) }
    }

    /// Listens for tunneled TCP connections on `port`.
    public func listen(port: UInt16) throws -> WireGuardListener {
        let listener = cmuxwg_listen(handle, Int32(port))
        guard listener > 0 else { throw Failure.library(operation: "listen", code: Int32(-listener)) }
        return WireGuardListener(handle: listener, queue: blocking)
    }

    /// Opens a tunneled TCP connection to `host:port`.
    public func connect(host: String, port: UInt16, timeout: Duration = .seconds(5)) async throws -> SocketStream {
        let handle = handle
        let millis = Int32(min(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000, Int64(Int32.max)))
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        return try await withCheckedThrowingContinuation { continuation in
            blocking.async {
                let fd = mutableCString(target) { cmuxwg_dial(handle, $0, millis) }
                if fd >= 0 {
                    continuation.resume(returning: SocketStream(fileDescriptor: fd))
                } else {
                    continuation.resume(throwing: Failure.library(operation: "connect", code: -fd))
                }
            }
        }
    }
}

/// A listener on the tunnel address.
public final class WireGuardListener: Sendable {
    private let handle: Int64
    private let queue: DispatchQueue

    init(handle: Int64, queue: DispatchQueue) {
        self.handle = handle
        self.queue = queue
    }

    deinit { close() }

    /// The next tunneled connection and the peer's tunnel address
    /// ("10.77.0.2"). Throws `.stopped` once the listener or tunnel closes;
    /// other failures lose one connection and the listener stays usable.
    public func accept() async throws -> (stream: SocketStream, peerAddress: String) {
        let handle = handle
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var peer = [CChar](repeating: 0, count: 80)
                let fd = cmuxwg_accept(handle, &peer, Int32(peer.count))
                guard fd >= 0 else {
                    // EBADF: the listener or tunnel is gone. Anything else
                    // (a socketpair that could not be made) lost one connection.
                    let error: WireGuardTunnel.Failure = -fd == EBADF ? .stopped : .library(operation: "accept", code: -fd)
                    return continuation.resume(throwing: error)
                }
                let remote = String(decoding: peer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let host = remote.split(separator: ":").first.map(String.init) ?? remote
                continuation.resume(returning: (SocketStream(fileDescriptor: fd), host))
            }
        }
    }

    /// Stops listening; a pending accept throws. Idempotent.
    public func close() {
        cmuxwg_close_listener(handle)
    }
}

/// cgo exports take `char *`; Swift bridges String only to `const char *`.
func mutableCString<R>(_ text: String, _ body: (UnsafeMutablePointer<CChar>) -> R) -> R {
    var bytes = Array(text.utf8CString)
    return bytes.withUnsafeMutableBufferPointer { buffer in
        // utf8CString always holds at least the terminating NUL.
        guard let base = buffer.baseAddress else {
            var empty: CChar = 0
            return body(&empty)
        }
        return body(base)
    }
}

/// Routes libcmuxwg log lines to os.Logger.
final class WireGuardLog: Sendable {
    static let logger = Logger(subsystem: "com.cmux.wireguard", category: "device")
    private static let installed = OSAllocatedUnfairLock(initialState: false)
    /// `CMUX_WG_LOG_STDERR=1` mirrors device logs to stderr (tests, debugging).
    static let mirrorToStderr = ProcessInfo.processInfo.environment["CMUX_WG_LOG_STDERR"] == "1"

    static func install() {
        let first = installed.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        cmuxwg_set_logger({ _, level, message in
            guard let message else { return }
            let text = String(cString: message)
            if WireGuardLog.mirrorToStderr { FileHandle.standardError.write(Data("cmuxwg: \(text)\n".utf8)) }
            if level > 0 {
                WireGuardLog.logger.error("\(text, privacy: .public)")
            } else {
                WireGuardLog.logger.debug("\(text, privacy: .public)")
            }
        }, nil)
    }
}
