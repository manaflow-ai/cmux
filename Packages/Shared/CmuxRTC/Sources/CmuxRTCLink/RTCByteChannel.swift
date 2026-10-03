import Foundation
@preconcurrency import WebRTC

public enum RTCChannelError: Error, Equatable {
    case closed
    case sendFailed
}

/// An ordered, reliable data channel used as a byte stream. Writes are split into 16 KiB messages
/// (libwebrtc's SCTP sends one message at a time per channel, so small messages keep other channels
/// interactive) and the writer waits while more than `highWater` bytes are unsent: libwebrtc closes
/// a channel whose send queue overflows, so the queue is never allowed to fill.
public final class RTCByteChannel: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    public static let messageSize = 16 * 1024
    public static let highWater: UInt64 = 1 << 20

    public let label: String
    private let channel: RTCDataChannel
    private let lock = NSRecursiveLock()
    private var outbox: [Data] = []
    private var outboxHead = 0
    private var outboxBytes = 0
    private var inbox: [Data] = []
    private var readers: [CheckedContinuation<Data?, Error>] = []
    private var writers: [CheckedContinuation<Void, Error>] = []
    private var openers: [CheckedContinuation<Void, Error>] = []
    private var isOpen = false
    private var isClosed = false

    init(channel: RTCDataChannel) {
        self.channel = channel
        label = channel.label
        super.init()
        isOpen = channel.readyState == .open
        isClosed = channel.readyState == .closed
        channel.delegate = self
    }

    /// Resolves once the channel is open; throws if it closes first.
    public func waitUntilOpen() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            defer { lock.unlock() }
            if isClosed { c.resume(throwing: RTCChannelError.closed) } else if isOpen { c.resume() } else { openers.append(c) }
        }
    }

    /// The next received chunk, or nil once the channel has closed and every chunk was read.
    public func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            lock.lock()
            defer { lock.unlock() }
            if !inbox.isEmpty { c.resume(returning: inbox.removeFirst()) } else if isClosed { c.resume(returning: nil) } else { readers.append(c) }
        }
    }

    /// Queues `data` in order and returns once the unsent backlog is at most `highWater`.
    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try enqueue(data)
        pump()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            defer { lock.unlock() }
            if isClosed { c.resume(throwing: RTCChannelError.closed) } else if UInt64(outboxBytes) <= Self.highWater { c.resume() } else { writers.append(c) }
        }
    }

    private func enqueue(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if isClosed { throw RTCChannelError.closed }
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.messageSize, data.count)
            outbox.append(data.subdata(in: offset..<end))
            offset = end
        }
        outboxBytes += data.count
    }

    public func close() {
        channel.close()
        finish()
    }

    private func pump() {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen, !isClosed else { return }
        while outboxHead < outbox.count, channel.bufferedAmount < Self.highWater {
            let chunk = outbox[outboxHead]
            guard channel.sendData(RTCDataBuffer(data: chunk, isBinary: true)) else {
                finish()
                return
            }
            outboxHead += 1
            outboxBytes -= chunk.count
        }
        if outboxHead == outbox.count {
            outbox.removeAll(keepingCapacity: true)
            outboxHead = 0
        } else if outboxHead > 64 {
            outbox.removeFirst(outboxHead)
            outboxHead = 0
        }
        if UInt64(outboxBytes) <= Self.highWater {
            let ready = writers
            writers.removeAll()
            for w in ready { w.resume() }
        }
    }

    private func finish() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        isOpen = false
        let pendingReaders = inbox.isEmpty ? readers : []
        if inbox.isEmpty { readers.removeAll() }
        let pendingWriters = writers
        let pendingOpeners = openers
        writers.removeAll()
        openers.removeAll()
        outbox.removeAll()
        outboxHead = 0
        outboxBytes = 0
        lock.unlock()
        for r in pendingReaders { r.resume(returning: nil) }
        for w in pendingWriters { w.resume(throwing: RTCChannelError.closed) }
        for o in pendingOpeners { o.resume(throwing: RTCChannelError.closed) }
    }

    // MARK: RTCDataChannelDelegate (libwebrtc's signaling thread)

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            lock.lock()
            isOpen = true
            let ready = openers
            openers.removeAll()
            lock.unlock()
            for o in ready { o.resume() }
            pump()
        case .closing, .closed:
            finish()
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        guard !data.isEmpty else { return }
        lock.lock()
        if let reader = readers.first {
            readers.removeFirst()
            lock.unlock()
            reader.resume(returning: data)
        } else {
            inbox.append(data)
            lock.unlock()
        }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        pump()
    }
}

/// Newline-delimited JSON over a byte channel (the cmux-tui v12 framing and the host RPC framing).
public final class RTCLineChannel: Sendable {
    public static let maxLine = 64 * 1024 * 1024

    public let bytes: RTCByteChannel

    public init(_ bytes: RTCByteChannel) { self.bytes = bytes }

    public var label: String { bytes.label }

    /// Writes one line; `line` must not contain a newline.
    public func send(_ line: Data) async throws {
        var framed = line
        framed.append(0x0A)
        try await bytes.write(framed)
    }

    /// Every received line in order; finishes when the channel closes, throws on an oversized line.
    public func lines() -> AsyncThrowingStream<Data, Error> {
        let bytes = self.bytes
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    while let chunk = try await bytes.read() {
                        buffer.append(chunk)
                        var start = buffer.startIndex
                        while let newline = buffer[start...].firstIndex(of: 0x0A) {
                            continuation.yield(Data(buffer[start..<newline]))
                            start = buffer.index(after: newline)
                        }
                        buffer = Data(buffer[start...])
                        if buffer.count > Self.maxLine { throw RTCLineChannelError.lineTooLong }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() { bytes.close() }
}

public enum RTCLineChannelError: Error, Equatable {
    case lineTooLong
}
