public import Foundation
import CmuxNextCompat
import Darwin
import Dispatch

/// One ``DaemonBridge`` stream for a caller that is not a daemon connection (a Cloud machine's
/// desktop, `cmux.rd/1` over `link dial --service desktop`): reads in order, a send, and one
/// close that ends the bridge child with the stream.
public nonisolated final class DaemonBridgeStream: Sendable {
    private struct Inbox {
        var pending: [Data] = []
        var ended = false
        var waiter: CheckedContinuation<Data?, Never>?
    }

    private let channel: DispatchIO
    private let inbox = Mutex(Inbox())
    private let child: BridgeChild

    init(descriptor: Int32, child: BridgeChild) {
        self.child = child
        let queue = DispatchQueue(label: "cmux.daemon-bridge.stream", qos: .userInitiated)
        channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in Darwin.close(descriptor) }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, bytes, error in
            if let bytes, !bytes.isEmpty { self?.deliver(Data(bytes)) }
            if done || error != 0 { self?.deliver(nil) }
        }
    }

    /// The next bytes from the bridge, in order; nil once it ended. One reader at a time.
    public func read() async -> Data? {
        await withCheckedContinuation { (waiter: CheckedContinuation<Data?, Never>) in
            let ready: Data?? = inbox.withLock { box in
                if !box.pending.isEmpty { return .some(box.pending.removeFirst()) }
                if box.ended { return .some(nil) }
                box.waiter = waiter
                return .none
            }
            if let ready { waiter.resume(returning: ready) }
        }
    }

    /// Writes `data` to the bridge; throws once the stream closed.
    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let channel = channel
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (answer: CheckedContinuation<Void, any Error>) in
            // concurrency-allow: short synchronous compare-and-set; DispatchIO may call back more than once.
            let answered = Mutex(false)
            channel.write(offset: 0, data: bytes, queue: .global(qos: .userInitiated)) { done, _, error in
                guard done || error != 0, answered.withLock({ state in if state { return false }; state = true; return true }) else { return }
                if error == 0 { answer.resume() } else { answer.resume(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)) }
            }
        }
    }

    /// Ends the stream and the bridge child; a waiting read answers nil. Idempotent.
    public func close() {
        deliver(nil)
        channel.close(flags: .stop)
        child.terminate()
    }

    deinit { close() }

    /// Bytes for the reader, or (nil) the end.
    private func deliver(_ data: Data?) {
        let (waiter, value): (CheckedContinuation<Data?, Never>?, Data?) = inbox.withLock { box in
            guard !box.ended else { return (nil, nil) }
            if let data {
                if let waiter = box.waiter {
                    box.waiter = nil
                    return (waiter, data)
                }
                box.pending.append(data)
                return (nil, nil)
            }
            box.ended = true
            defer { box.waiter = nil }
            return (box.waiter, nil)
        }
        waiter?.resume(returning: value)
    }
}

extension DaemonBridge {
    /// Spawns the bridge, waits for its dial line, and returns the connected stream; throws why
    /// the dial failed (the child is then killed and reaped). Blocking (up to the dial line's
    /// deadline): call it off the main actor.
    public func openStream() throws(DaemonError) -> DaemonBridgeStream {
        let (fd, child) = try open()
        return DaemonBridgeStream(descriptor: fd, child: child)
    }
}
