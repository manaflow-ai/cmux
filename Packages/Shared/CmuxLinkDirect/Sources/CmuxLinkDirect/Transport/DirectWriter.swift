import CmuxLink
import Foundation

/// The send half of a direct transport. A single TCP stream still requires
/// records to be written in nonce order, but queued frames are selected by
/// lane priority so interactive traffic can pass queued bulk. The pending
/// bulk budget is bounded to one maximum-sized frame (D2 F7).
actor DirectWriter {
    static let maxQueuedBulkBytes = TransportCapabilities.stream.maxFrameBytes

    private struct AdmissionWaiter {
        let id: UInt64
        let bytes: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Pending {
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let socket: any DirectWriterSocket
    private var cipher: NoiseCipherState
    private var queue = DirectSendQueue(maxQueuedBulkBytes: DirectWriter.maxQueuedBulkBytes)
    private var pending: [UInt64: Pending] = [:]
    private var admissionWaiters: [AdmissionWaiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextID: UInt64 = 0
    private var draining = false
    private var activeBulkBytes = 0
    private var activePending: Pending?
    private var activeID: UInt64?
    private var closing = false
    private var bytesPerSecond: Int?

    init(socket: any DirectWriterSocket, cipher: NoiseCipherState, bytesPerSecond: Int? = nil) {
        self.socket = socket
        self.cipher = cipher
        self.bytesPerSecond = bytesPerSecond
    }

    func write(_ frame: TransportFrame) async throws {
        let queuedAt = ContinuousClock.now
        guard !closing else { throw DirectTransportError.closed }
        if frame.lane.priority == .bulk, frame.bytes.count > Self.maxQueuedBulkBytes {
            throw DirectTransportError.frameTooLarge(frame.bytes.count)
        }
        // Unordered media is dropped rather than queued behind a busy writer.
        if case .unreliableUnordered = frame.lane.reliability,
           draining || !queue.isEmpty || !admissionWaiters.isEmpty { return }

        while !canEnqueue(frame) {
            try await waitForBulkCapacity(bytes: frame.bytes.count)
            try Task.checkCancellation()
            guard !closing else { throw DirectTransportError.closed }
        }

        let id = nextID
        nextID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = Pending(continuation: continuation)
                queue.enqueue(DirectSendQueue.Entry(id: id, frame: frame, queuedAt: queuedAt))
                startDrainIfNeeded()
            }
        } onCancel: {
            Task { await self.cancelQueued(id: id) }
        }
    }

    /// Sends `close` after every write already accepted, then refuses more.
    func closeGracefully() async {
        guard !closing else { return }
        closing = true
        let admissions = admissionWaiters
        admissionWaiters.removeAll()
        for waiter in admissions { waiter.continuation.resume(throwing: DirectTransportError.closed) }
        await waitUntilIdle()
        do { try await socket.send(record: try cipher.encrypt(DirectRecord.close.encoded())) } catch {}
    }

    /// The transport died: waiting writes fail.
    func fail() {
        closing = true
        let pending = self.pending
        self.pending.removeAll()
        queue.removeAll()
        for waiter in pending.values { waiter.continuation.resume(throwing: DirectTransportError.closed) }
        activePending?.continuation.resume(throwing: DirectTransportError.closed)
        activePending = nil

        let admissions = admissionWaiters
        admissionWaiters.removeAll()
        for waiter in admissions { waiter.continuation.resume(throwing: DirectTransportError.closed) }

        let idle = idleWaiters
        idleWaiters.removeAll()
        for waiter in idle { waiter.resume() }
    }

    func setRate(_ bytesPerSecond: Int?) {
        self.bytesPerSecond = bytesPerSecond
    }

    private func pace(_ count: Int) async throws {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return }
        try await ContinuousClock().sleep(for: .seconds(Double(count) / Double(bytesPerSecond)))
    }

    private func startDrainIfNeeded() {
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while let entry = queue.dequeue() {
            guard let pending = pending.removeValue(forKey: entry.id) else {
                wakeAdmissionWaiters()
                continue
            }
            activeID = entry.id
            activePending = pending
            if entry.frame.lane.priority == .bulk {
                activeBulkBytes = entry.frame.bytes.count
            }
            do {
                if case let .partial(maxLifetime) = entry.frame.lane.reliability,
                   ContinuousClock.now - entry.queuedAt > maxLifetime {
                    activePending?.continuation.resume()
                } else {
                    try await pace(entry.frame.bytes.count)
                    for record in DirectRecord.segments(of: entry.frame) {
                        try await socket.send(record: try cipher.encrypt(record.encoded()))
                    }
                    activePending?.continuation.resume()
                }
            } catch {
                activePending?.continuation.resume(throwing: error)
            }
            activePending = nil
            activeID = nil
            activeBulkBytes = 0
            wakeAdmissionWaiters()
        }
        draining = false
        resumeIdleWaitersIfNeeded()
        if !queue.isEmpty { startDrainIfNeeded() }
    }

    private func waitForBulkCapacity(bytes: Int) async throws {
        let id = nextID
        nextID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // The cancellation handler may run before this operation is
                // entered when the caller was already canceled. Resume here
                // as well so a waiter cannot be appended after the handler's
                // actor hop has already looked for it.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if closing {
                    continuation.resume(throwing: DirectTransportError.closed)
                } else if canEnqueueBulk(bytes: bytes) {
                    continuation.resume()
                } else {
                    admissionWaiters.append(AdmissionWaiter(id: id, bytes: bytes, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelAdmission(id: id) }
        }
    }

    private func wakeAdmissionWaiters() {
        while let waiter = admissionWaiters.first,
              canEnqueueBulk(bytes: waiter.bytes) {
            admissionWaiters.removeFirst().continuation.resume()
        }
    }

    private func cancelAdmission(id: UInt64) {
        guard let index = admissionWaiters.firstIndex(where: { $0.id == id }) else { return }
        admissionWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelQueued(id: UInt64) {
        if activeID == id {
            // NWConnection has no per-send cancellation. Closing it wakes a
            // blocked contentProcessed callback; the continuation is resumed
            // here so the caller observes cancellation even if that callback
            // arrives late. The drain sees the cleared active slot and cannot
            // resume it a second time.
            let active = activePending
            activePending = nil
            activeID = nil
            socket.cancel()
            active?.continuation.resume(throwing: CancellationError())
            return
        }
        guard let pending = pending.removeValue(forKey: id) else { return }
        queue.remove(id: id)
        pending.continuation.resume(throwing: CancellationError())
        wakeAdmissionWaiters()
    }

    private func canEnqueue(_ frame: TransportFrame) -> Bool {
        guard frame.lane.priority == .bulk else { return true }
        return canEnqueueBulk(bytes: frame.bytes.count)
    }

    private func canEnqueueBulk(bytes: Int) -> Bool {
        bytes >= 0 && activeBulkBytes + queue.queuedBulkBytes + bytes <= Self.maxQueuedBulkBytes
    }

    private func waitUntilIdle() async {
        guard draining || !queue.isEmpty else { return }
        await withCheckedContinuation { continuation in
            if !draining && queue.isEmpty { continuation.resume() } else { idleWaiters.append(continuation) }
        }
    }

    private func resumeIdleWaitersIfNeeded() {
        guard !draining && queue.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
