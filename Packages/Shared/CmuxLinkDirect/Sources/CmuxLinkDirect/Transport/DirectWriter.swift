import CmuxLink
import Foundation

/// The send half of a direct transport: owns the send cipher and keeps
/// records in send order. One write runs at a time (a FIFO gate), so a
/// frame's segments are contiguous and nonces follow wire order.
actor DirectWriter {
    private let socket: DirectSocket
    private var cipher: NoiseCipherState
    private var busy = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextWaiterID: UInt64 = 0
    private var closing = false
    private var bytesPerSecond: Int?

    init(socket: DirectSocket, cipher: NoiseCipherState, bytesPerSecond: Int? = nil) {
        self.socket = socket
        self.cipher = cipher
        self.bytesPerSecond = bytesPerSecond
    }

    func write(_ frame: TransportFrame) async throws {
        let queuedAt = ContinuousClock.now
        guard !closing else { throw DirectTransportError.closed }
        // Media semantics: an unordered frame never queues behind a busy writer.
        if case .unreliableUnordered = frame.lane.reliability, busy { return }
        try await acquire()
        defer { release() }
        // Writes queued before `closeGracefully` still go out ahead of `close`.
        if case let .partial(maxLifetime) = frame.lane.reliability, ContinuousClock.now - queuedAt > maxLifetime {
            return
        }
        try await pace(frame.bytes.count)
        for record in DirectRecord.segments(of: frame) {
            try await socket.send(record: try cipher.encrypt(record.encoded()))
        }
    }

    /// Sends `close` after every write already accepted, then refuses more.
    func closeGracefully() async {
        guard !closing else { return }
        closing = true
        do {
            try await acquire(ignoringClose: true)
            defer { release() }
            try await socket.send(record: try cipher.encrypt(DirectRecord.close.encoded()))
        } catch {}
    }

    /// The transport died: waiting writes fail.
    func fail() {
        closing = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: DirectTransportError.closed) }
    }

    func setRate(_ bytesPerSecond: Int?) {
        self.bytesPerSecond = bytesPerSecond
    }

    private func pace(_ count: Int) async throws {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return }
        try await ContinuousClock().sleep(for: .seconds(Double(count) / Double(bytesPerSecond)))
    }

    private func acquire(ignoringClose: Bool = false) async throws {
        if !ignoringClose, closing { throw DirectTransportError.closed }
        guard busy else {
            busy = true
            return
        }
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}
