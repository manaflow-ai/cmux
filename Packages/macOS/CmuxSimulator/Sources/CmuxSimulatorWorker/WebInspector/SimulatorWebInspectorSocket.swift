import Darwin
import Foundation

protocol SimulatorWebInspectorTransport: AnyObject, Sendable {
    var messages: AsyncStream<Data> { get }
    func send(propertyList: [String: Any]) throws
    func close()
}

/// Full-duplex Unix socket whose blocking reader is confined to one thread.
///
/// The descriptor and close transition are protected by `lock`; writes are
/// issued only by the worker's main actor. This narrow invariant is why the
/// reference type can cross into its reader thread safely.
final class SimulatorWebInspectorSocket: SimulatorWebInspectorTransport, @unchecked Sendable {
    /// Only one decoded plist body may wait behind the consumer. If inspectord
    /// outruns that budget, the worker drops the socket instead of buffering a
    /// burst of potentially 64 MiB frames.
    static let maximumBufferedBodyCount = 1
    static let maximumBufferedBodyBytes =
        maximumBufferedBodyCount * SimulatorWebInspectorPlistFrameCodec.maximumBodyLength

    let messages: AsyncStream<Data>

    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private var descriptor: Int32
    private var isClosing = false
    private var reader: Thread?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
        let pair = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedBodyCount)
        )
        messages = pair.stream
        continuation = pair.continuation
        startReader()
    }

    static func connect(path: String) throws -> SimulatorWebInspectorSocket {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < pathCapacity else {
            throw SimulatorWebInspectorError.invalidSocketPath
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SimulatorWebInspectorError.socketFailure(errno)
        }
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw SimulatorWebInspectorError.socketFailure(failure)
        }
        return SimulatorWebInspectorSocket(descriptor: descriptor)
    }

    func send(propertyList: [String: Any]) throws {
        let frame = try SimulatorWebInspectorPlistFrameCodec.frame(propertyList)
        try lock.withLock {
            guard descriptor >= 0, !isClosing else {
                throw SimulatorWebInspectorError.transportClosed
            }
            try frame.withUnsafeBytes { raw in
                guard let baseAddress = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        raw.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written == -1, errno == EINTR {
                        continue
                    } else {
                        throw SimulatorWebInspectorError.socketFailure(errno)
                    }
                }
            }
        }
    }

    func close() {
        requestClose()
    }

    private func startReader() {
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "cmux-simulator-web-inspector"
        thread.stackSize = 1 << 20
        reader = thread
        thread.start()
    }

    private func readLoop() {
        while let header = readExactly(4) {
            let length: Int
            do {
                length = try SimulatorWebInspectorPlistFrameCodec.bodyLength(header: header)
            } catch {
                break
            }
            guard let body = readExactly(length) else { break }
            switch continuation.yield(body) {
            case .enqueued:
                continue
            case .dropped, .terminated:
                requestClose()
                finishReader()
                return
            @unknown default:
                requestClose()
                finishReader()
                return
            }
        }
        finishReader()
    }

    private func readExactly(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let currentDescriptor = lock.withLock { isClosing ? -1 : descriptor }
            guard currentDescriptor >= 0 else { return nil }
            let received = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let baseAddress = raw.baseAddress else { return -1 }
                return Darwin.read(
                    currentDescriptor,
                    baseAddress.advanced(by: offset),
                    count - offset
                )
            }
            if received > 0 {
                offset += received
            } else if received == -1, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return Data(bytes)
    }

    private func requestClose() {
        let closingDescriptor: Int32? = lock.withLock {
            guard descriptor >= 0, !isClosing else { return nil }
            isClosing = true
            return descriptor
        }
        if let closingDescriptor {
            Darwin.shutdown(closingDescriptor, SHUT_RDWR)
        }
        continuation.finish()
    }

    private func finishReader() {
        let closingDescriptor: Int32? = lock.withLock {
            guard descriptor >= 0 else { return nil }
            let value = descriptor
            descriptor = -1
            isClosing = true
            return value
        }
        if let closingDescriptor { Darwin.close(closingDescriptor) }
        continuation.finish()
    }
}
