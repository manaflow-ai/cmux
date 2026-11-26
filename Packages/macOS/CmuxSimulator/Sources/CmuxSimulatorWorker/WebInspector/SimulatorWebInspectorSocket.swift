import Darwin
import Foundation

/// Full-duplex Unix socket whose blocking reader is confined to one thread.
///
/// The immutable descriptor stays open until deinitialization, so shutdown can
/// safely race a read without descriptor reuse. Writes are isolated to the
/// worker's main actor, which is the safety argument for unchecked Sendable.
final class SimulatorWebInspectorSocket: SimulatorWebInspectorTransport, @unchecked Sendable {
    /// Only one decoded plist body may wait behind the consumer. If inspectord
    /// outruns that budget, the worker drops the socket instead of buffering a
    /// burst of potentially 64 MiB frames.
    static let maximumBufferedBodyCount = 1
    static let maximumBufferedBodyBytes = maximumBufferedBodyCount * 64 * 1024 * 1024
    static let maximumPendingWriteBytes = 4 * 1024 * 1024
    static let writeDeadline: TimeInterval = 5

    let messages: AsyncStream<Data>

    private let frameCodec: SimulatorWebInspectorPlistFrameCodec
    private let continuation: AsyncStream<Data>.Continuation
    private let descriptor: Int32
    private let writerQueue = DispatchQueue(label: "com.cmux.simulator.web-inspector-writer")
    @MainActor private var pendingWriteBytes = 0
    @MainActor private var writesClosed = false

    init(descriptor: Int32, frameCodec: SimulatorWebInspectorPlistFrameCodec) {
        self.descriptor = descriptor
        self.frameCodec = frameCodec
        let pair = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedBodyCount)
        )
        messages = pair.stream
        continuation = pair.continuation
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
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "cmux-simulator-web-inspector"
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func readLoop() {
        while let header = readExactly(4) {
            let length: Int
            do {
                length = try frameCodec.bodyLength(header: header)
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
        continuation.finish()
        Task { @MainActor [weak self] in
            self?.writesClosed = true
        }
    }

    private nonisolated func finishReader() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
        continuation.finish()
    }
}
