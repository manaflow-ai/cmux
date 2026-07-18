import CmuxTerminalBackend
import Darwin
import Dispatch
import Foundation

final class TestUnixSocketServer: @unchecked Sendable {
    let path: String

    private let lock = NSLock()
    private var listener: Int32?

    init() throws {
        path = "/tmp/cmux-tb-\(UUID().uuidString.prefix(12)).sock"
        Darwin.unlink(path)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.posixError() }

        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: bytes)
                destination[bytes.count] = 0
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard result == 0 else { throw Self.posixError() }
            guard Darwin.listen(descriptor, 1) == 0 else { throw Self.posixError() }
            listener = descriptor
        } catch {
            Darwin.close(descriptor)
            Darwin.unlink(path)
            throw error
        }
    }

    deinit {
        stop()
    }

    func acceptConnection() async throws -> TestUnixSocketConnection {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let descriptor = try listenerDescriptor()
                    let connection = Darwin.accept(descriptor, nil, nil)
                    guard connection >= 0 else { throw Self.posixError() }
                    continuation.resume(returning: TestUnixSocketConnection(connection))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func echoOneLine() async throws {
        let connection = try await acceptConnection()
        let line = try await connection.receiveLine()
        try await connection.send(line + Data([0x0A]))
        connection.close()
    }

    func stop() {
        let descriptor = lock.withLock {
            let descriptor = listener
            listener = nil
            return descriptor
        }
        if let descriptor {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        Darwin.unlink(path)
    }

    private func listenerDescriptor() throws -> Int32 {
        try lock.withLock {
            guard let listener else { throw CocoaError(.fileNoSuchFile) }
            return listener
        }
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

final class TestUnixSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    func receiveLine() async throws -> Data {
        try await receiveLines(count: 1)[0]
    }

    func receiveLines(count expectedCount: Int) async throws -> [Data] {
        precondition(expectedCount > 0)
        return try await runBlocking { descriptor in
            var line = Data()
            var lines: [Data] = []
            var storage = [UInt8](repeating: 0, count: 4_096)
            while lines.count < expectedCount {
                let count = storage.withUnsafeMutableBytes {
                    Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
                }
                if count > 0 {
                    line.append(contentsOf: storage.prefix(count))
                    while let newline = line.firstIndex(of: 0x0A) {
                        lines.append(Data(line[..<newline]))
                        line.removeSubrange(...newline)
                        if lines.count == expectedCount {
                            return lines
                        }
                    }
                } else if count == 0 {
                    throw BackendProtocolError.connectionClosed
                } else if errno != EINTR {
                    throw Self.posixError()
                }
            }
            return lines
        }
    }

    func send(_ data: Data) async throws {
        try await runBlocking { descriptor in
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { bytes in
                    Darwin.send(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset,
                        0
                    )
                }
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw count == 0
                        ? BackendProtocolError.connectionClosed
                        : Self.posixError()
                }
            }
        }
    }

    func availableByteCount() throws -> Int {
        let descriptor = try openDescriptor()
        var byte: UInt8 = 0
        let count = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count >= 0 {
            return count
        }
        guard errno == EAGAIN || errno == EWOULDBLOCK else {
            throw Self.posixError()
        }
        return 0
    }

    func drainUntilEOF(timeoutMilliseconds: Int) async throws -> Data {
        try await runBlocking { descriptor in
            var received = Data()
            var storage = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLHUP),
                    revents: 0
                )
                let pollResult = Darwin.poll(
                    &pollDescriptor,
                    1,
                    Int32(clamping: timeoutMilliseconds)
                )
                if pollResult == 0 {
                    throw Self.posixError(ETIMEDOUT)
                }
                if pollResult < 0 {
                    guard errno == EINTR else { throw Self.posixError() }
                    continue
                }
                let count = storage.withUnsafeMutableBytes {
                    Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
                }
                if count > 0 {
                    received.append(contentsOf: storage.prefix(count))
                } else if count == 0 {
                    return received
                } else if errno != EINTR {
                    throw Self.posixError()
                }
            }
        }
    }

    func close() {
        let descriptor = lock.withLock {
            let descriptor = self.descriptor
            self.descriptor = nil
            return descriptor
        }
        if let descriptor {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func runBlocking<Result: Sendable>(
        _ operation: @escaping @Sendable (Int32) throws -> Result
    ) async throws -> Result {
        let descriptor = try openDescriptor()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation(descriptor))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func openDescriptor() throws -> Int32 {
        try lock.withLock {
            guard let descriptor else { throw BackendProtocolError.connectionClosed }
            return descriptor
        }
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
