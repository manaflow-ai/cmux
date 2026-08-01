import Darwin
import Foundation

/// Full-duplex Unix socket whose blocking I/O is confined to serial queues.
///
/// Safety: the immutable descriptor stays open until deinitialization, shutdown
/// can safely race a read without descriptor reuse, and the reader and writer
/// queues serialize their respective blocking operations. Main-actor state
/// bounds queued writes. These invariants make unchecked Sendable safe.
final class SimulatorWebInspectorSocket: SimulatorWebInspectorTransport, @unchecked Sendable {
    /// Decoded plist bodies share one aggregate byte budget. This accepts
    /// inspectord's small census burst without admitting multiple 64 MiB frames.
    static let maximumBufferedBodyBytes = 64 * 1024 * 1024
    static let maximumPendingWriteBytes = 4 * 1024 * 1024
    static let writeDeadline: TimeInterval = 5

    let messages: SimulatorWebInspectorMessageStream

    private let frameCodec: SimulatorWebInspectorPlistFrameCodec
    private let descriptor: Int32
    private let readerQueue = DispatchQueue(label: "com.cmux.simulator.web-inspector-reader")
    private let writerQueue = DispatchQueue(label: "com.cmux.simulator.web-inspector-writer")
    @MainActor private var pendingWriteBytes = 0
    @MainActor private var writesClosed = false

    init(descriptor: Int32, frameCodec: SimulatorWebInspectorPlistFrameCodec) {
        self.descriptor = descriptor
        self.frameCodec = frameCodec
        messages = SimulatorWebInspectorMessageStream(
            maximumBufferedBytes: Self.maximumBufferedBodyBytes
        )
        startReader()
    }

    deinit {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    @MainActor
    func send(propertyList: [String: Any]) throws {
        let frame = try frameCodec.frame(propertyList)
        guard !writesClosed else {
            throw SimulatorWebInspectorError.transportClosed
        }
        guard frame.count <= Self.maximumPendingWriteBytes,
              pendingWriteBytes <= Self.maximumPendingWriteBytes - frame.count else {
            requestClose()
            throw SimulatorWebInspectorError.socketFailure(ENOBUFS)
        }
        pendingWriteBytes += frame.count

        writerQueue.async { [weak self] in
            self?.write(frame)
        }
    }

    @MainActor
    func close() {
        requestClose()
    }

    private func startReader() {
        Task { [weak self] in
            await self?.readLoop()
        }
    }

    private func readLoop() async {
        while let header = await readExactly(4) {
            let length: Int
            do {
                length = try frameCodec.bodyLength(header: header)
            } catch {
                break
            }
            guard let body = await readExactly(length) else { break }
            switch await messages.yield(body) {
            case .enqueued:
                continue
            case .overflow, .terminated:
                requestClose()
                return
            }
        }
        await finishReader()
    }

    private func readExactly(_ count: Int) async -> Data? {
        await withCheckedContinuation { continuation in
            readerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.readExactlyBlocking(count))
            }
        }
    }

    private func readExactlyBlocking(_ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { raw -> Int in
                guard let baseAddress = raw.baseAddress else { return -1 }
                return Darwin.read(
                    descriptor,
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

    private func write(_ frame: Data) {
        defer {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingWriteBytes = max(0, self.pendingWriteBytes - frame.count)
            }
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(Self.writeDeadline * 1_000_000_000)
        var offset = 0
        let failure = frame.withUnsafeBytes { raw -> Int32? in
            guard let baseAddress = raw.baseAddress else { return nil }
            while offset < raw.count {
                let written = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    raw.count - offset,
                    MSG_DONTWAIT | MSG_NOSIGNAL
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    return written < 0 ? errno : EIO
                }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return ETIMEDOUT }
                let remainingMilliseconds = max(
                    1,
                    Int32(min((deadline - now) / 1_000_000, UInt64(Int32.max)))
                )
                var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let result = Darwin.poll(&event, 1, remainingMilliseconds)
                if result > 0 { continue }
                if result < 0, errno == EINTR { continue }
                return result == 0 ? ETIMEDOUT : errno
            }
            return nil
        }
        if failure != nil { requestClose() }
    }

    private nonisolated func requestClose() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Task { [messages] in
            await messages.finish()
        }
        Task { @MainActor [weak self] in
            self?.writesClosed = true
        }
    }

    private func finishReader() async {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        await messages.finish()
    }
}
