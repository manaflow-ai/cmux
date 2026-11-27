import Darwin
import Foundation

@testable import CmuxIrxTransport

/// A blocking loopback TCP server on its own thread.
/// `.echo` echoes every byte and, after the client half-closes, writes
/// `<eof>` and closes, so a test can see a half-close cross the tunnel.
final class TunnelTestTCPServer: @unchecked Sendable {
    enum Mode { case echo }

    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false

    init(mode: Mode) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        listenFD = fd
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            Thread { Self.echo(client) }.start()
        }
    }

    private static func echo(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer[offset..<count].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if written <= 0 { close(fd); return }
                offset += written
            }
        }
        let trailer = Array("<eof>".utf8)
        _ = trailer.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }
}

/// An in-memory lane: the test plays the phone.
actor FakeTunnelLane: IrxTunnelLane {
    nonisolated let descriptor: IrxLaneDescriptor
    private var inbound: [Data?] = []
    private var readWaiter: CheckedContinuation<Data?, any Error>?
    private(set) var frames: [Data] = []
    private(set) var written = Data()
    private(set) var finished = false
    private(set) var aborted = false
    private var doneWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ descriptor: IrxLaneDescriptor) {
        self.descriptor = descriptor
    }

    /// Phone -> Mac bytes; nil is the phone's half-close.
    func push(_ data: Data?) {
        if let readWaiter {
            self.readWaiter = nil
            readWaiter.resume(returning: data)
        } else {
            inbound.append(data)
        }
    }

    func readRaw(maximumByteCount: Int) async throws -> Data? {
        if aborted { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { readWaiter = $0 }
    }

    func write(_ data: Data) async throws {
        if aborted { throw CancellationError() }
        written.append(data)
    }

    func writeFrame(_ value: some Encodable & Sendable) async throws {
        if aborted { throw CancellationError() }
        frames.append(try JSONEncoder().encode(value))
    }

    func finish() async {
        finished = true
        signalDone()
    }

    func abort() async {
        aborted = true
        readWaiter?.resume(throwing: CancellationError())
        readWaiter = nil
        signalDone()
    }

    private func signalDone() {
        for waiter in doneWaiters { waiter.resume() }
        doneWaiters.removeAll()
    }

    /// Waits until the Mac finished or aborted this lane.
    func waitDone() async {
        if finished || aborted { return }
        await withCheckedContinuation { doneWaiters.append($0) }
    }

    func openReply() throws -> IrxTunnelOpenReply? {
        try frames.first.map { try JSONDecoder().decode(IrxTunnelOpenReply.self, from: $0) }
    }

    func portsReply() throws -> IrxListeningPortsReply? {
        try frames.first.map { try JSONDecoder().decode(IrxListeningPortsReply.self, from: $0) }
    }
}

/// Records connect attempts and hands out channels that never answer.
final class FakeTunnelConnector: IrxTunnelConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts: [([IrxTunnelIPAddress], Int)] = []
    private var _resolved: [String] = []
    var resolution: [String: [IrxTunnelIPAddress]] = [:]
    var failure: IrxTunnelOpenReply.Status?
    private(set) var channels: [FakeTunnelChannel] = []

    var attempts: [([IrxTunnelIPAddress], Int)] { lock.withLock { _attempts } }
    var resolvedNames: [String] { lock.withLock { _resolved } }

    func resolve(host: String) async -> [IrxTunnelIPAddress] {
        lock.withLock {
            _resolved.append(host)
            return resolution[host] ?? []
        }
    }

    func connect(
        to addresses: [IrxTunnelIPAddress],
        port: Int,
        timeout: Duration
    ) async throws(IrxTunnelOpenError) -> any IrxTunnelByteChannel {
        let (failure, channel): (IrxTunnelOpenReply.Status?, FakeTunnelChannel) = lock.withLock {
            _attempts.append((addresses, port))
            let channel = FakeTunnelChannel()
            channels.append(channel)
            return (self.failure, channel)
        }
        if let failure { throw IrxTunnelOpenError(status: failure) }
        return channel
    }
}

/// A TCP stand-in that holds its receive side open until cancelled.
final class FakeTunnelChannel: IrxTunnelByteChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var _cancelled = false

    var cancelled: Bool { lock.withLock { _cancelled } }

    func receive(maximumByteCount: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if _cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    func send(_ data: Data) async throws {
        if cancelled { throw CancellationError() }
    }

    func finishSending() async {}

    func cancel() {
        lock.lock()
        _cancelled = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
    }
}

/// A controllable clock for the open-rate bucket.
final class TunnelTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { current } }

    func advance(_ duration: Duration) {
        lock.withLock { current = current + duration }
    }
}
