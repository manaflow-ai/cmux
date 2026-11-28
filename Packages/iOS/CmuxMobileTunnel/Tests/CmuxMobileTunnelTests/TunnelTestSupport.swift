import Darwin
import Foundation
@testable import CmuxMobileTunnel

/// An in-memory exit that echoes what it is sent. After the phone side
/// half-closes it sends `<eof>` and finishes, so a test can watch a
/// half-close cross the relay in both directions.
final class EchoExit: TunnelByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data?] = []
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var _closed = false
    private var _received = Data()

    var closed: Bool { lock.withLock { _closed } }
    var received: Data { lock.withLock { _received } }

    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if _closed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else if !queue.isEmpty {
                let next = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    private func enqueue(_ data: Data?) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
        } else {
            queue.append(data)
            lock.unlock()
        }
    }

    func write(_ data: Data) async throws {
        if closed { throw TunnelOpenError.generalFailure }
        lock.withLock { _received.append(data) }
        enqueue(data)
    }

    func finishWriting() async {
        enqueue(Data("<eof>".utf8))
        enqueue(nil)
    }

    func close() async {
        let waiter = lock.withLock { () -> CheckedContinuation<Data?, any Error>? in
            _closed = true
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}

/// A backend with scripted outcomes that records every open.
final class ScriptedBackend: SocksConnectBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _opens: [(String, Int)] = []
    private var _exits: [EchoExit] = []
    var failure: (any Error)?

    var opens: [(String, Int)] { lock.withLock { _opens } }
    var exits: [EchoExit] { lock.withLock { _exits } }

    func open(host: String, port: Int) async throws -> any TunnelByteStream {
        let failure: (any Error)? = lock.withLock {
            _opens.append((host, port))
            return self.failure
        }
        if let failure { throw failure }
        let exit = EchoExit()
        lock.withLock { _exits.append(exit) }
        return exit
    }
}

/// Blocking TCP client for exercising the phone-side listeners byte for byte.
enum RawClient {
    static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    static func send(_ fd: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    static func receive(_ fd: Int32, count: Int) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < count {
            let read = Darwin.read(fd, &buffer, min(buffer.count, count - result.count))
            if read <= 0 { break }
            result += buffer[0..<read]
        }
        return result
    }

    static func receiveAll(_ fd: Int32) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = Darwin.read(fd, &buffer, buffer.count)
            if read <= 0 { break }
            result += buffer[0..<read]
        }
        return result
    }

    static func socksConnect(host: String, port: Int) -> [UInt8] {
        let name = Array(host.utf8)
        return [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)]
    }
}
