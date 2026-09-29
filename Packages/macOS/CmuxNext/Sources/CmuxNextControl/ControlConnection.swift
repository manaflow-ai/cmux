import CmuxNextSettings
import Darwin
import Foundation

/// One accepted client. All socket IO runs on a private serial queue:
/// nonblocking reads split lines for a single consumer task, and responses
/// go through a nonblocking, capped write buffer, so a slow or stuck client
/// can only stall its own connection.
///
/// Bounds (architecture.md 5a, "no unbounded buffers"):
/// - inbound: at most `maxQueuedLines` parsed lines wait for the consumer;
///   beyond that the read source is suspended and the kernel socket buffer
///   pushes back on the client.
/// - outbound: at most `maxOutboxBytes` of unsent responses; a client that
///   stops reading past that is disconnected.
/// - close: queued responses get `drainTimeout` to flush after `close()`.
final class ControlConnection: @unchecked Sendable {
    struct Limits: Sendable {
        var maxLineBytes: Int
        var maxQueuedLines = 64
        var maxOutboxBytes = 8 << 20
        var drainTimeout: DispatchTimeInterval = .seconds(5)
    }

    let id: ControlConnectionID
    private let descriptor: Int32
    private let limits: Limits
    private let queue: DispatchQueue
    // Queue-confined.
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var drainTimer: (any DispatchSourceTimer)?
    private var liveSources = 0
    private var inbound = Data()
    private var queuedLines = 0
    private var isReadSuspended = false
    private var isInputFinished = false
    private var outbox = Data()
    private var outboxOffset = 0
    private var isWriteArmed = false
    private var isCloseRequested = false
    private var isClosed = false
    private var continuation: AsyncStream<String>.Continuation?
    private var consumer: Task<Void, Never>?
    private var hangupWaiters: [CheckedContinuation<Void, Never>] = []
    /// Called once on the connection queue after the descriptor closed.
    var onClosed: (@Sendable () -> Void)?

    init(id: ControlConnectionID, descriptor: Int32, limits: Limits) {
        self.id = id
        self.descriptor = descriptor
        self.limits = limits
        self.queue = DispatchQueue(label: "com.cmuxterm.next.control.\(id)")
    }

    func start(consume: @escaping @Sendable (AsyncStream<String>) async -> Void) {
        // The stream never exceeds `maxQueuedLines`: reading pauses first.
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        queue.async { [self] in
            self.continuation = continuation
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [weak self] in self?.sourceCancelled() }
            readSource = source
            liveSources += 1
            source.resume()
            consumer = Task { await consume(stream) }
        }
    }

    /// Queues one response line. Never blocks the caller.
    func send(_ line: String) {
        var data = Data(line.utf8)
        data.append(0x0A)
        queue.async { [self] in
            guard !isClosed else { return }
            if outbox.count - outboxOffset + data.count > limits.maxOutboxBytes {
                // The client stopped reading; drop it rather than buffer without limit.
                closeNow()
                return
            }
            outbox.append(data)
            flush()
        }
    }

    /// Returns once the client stopped sending (EOF, error) or the
    /// connection closed (a failed write to a gone client closes it).
    func hangup() async {
        await withCheckedContinuation { waiter in
            queue.async { [self] in
                if isInputFinished || isClosed { waiter.resume() } else { hangupWaiters.append(waiter) }
            }
        }
    }

    private func resumeHangupWaiters() {
        let waiters = hangupWaiters
        hangupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// The consumer finished one line; reading may resume.
    func lineConsumed() {
        queue.async { [self] in
            queuedLines = max(0, queuedLines - 1)
            emitLines()
            if isReadSuspended, !isInputFinished, queuedLines < limits.maxQueuedLines, !isClosed {
                isReadSuspended = false
                readSource?.resume()
            }
        }
    }

    /// Stops reading and closes once queued responses flushed (or after
    /// `drainTimeout`).
    func close() {
        queue.async { [self] in
            guard !isClosed, !isCloseRequested else { return }
            isCloseRequested = true
            finishInput()
            if outboxOffset >= outbox.count {
                closeNow()
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + limits.drainTimeout)
            timer.setEventHandler { [weak self] in self?.closeNow() }
            drainTimer = timer
            timer.resume()
        }
    }

    // MARK: - Queue-confined

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !isReadSuspended, !isInputFinished {
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                inbound.append(chunk, count: count)
                emitLines()
                if inbound.count > limits.maxLineBytes, inbound.firstIndex(of: 0x0A) == nil {
                    let error = ControlError(code: "request_too_large", message: ControlStrings.format("control.error.requestTooLarge", "Request line exceeds %lld bytes", limits.maxLineBytes))
                    outbox.append(Data((ControlWire.encode(id: nil, error: error) + "\n").utf8))
                    flush()
                    finishInput()
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            // EOF or error: the consumer drains what it has, then closes.
            finishInput()
            return
        }
    }

    /// Hands complete lines to the consumer until `maxQueuedLines` wait,
    /// then suspends reading.
    private func emitLines() {
        while queuedLines < limits.maxQueuedLines, let newline = inbound.firstIndex(of: 0x0A) {
            let lineData = inbound[inbound.startIndex..<newline]
            inbound.removeSubrange(inbound.startIndex...newline)
            queuedLines += 1
            continuation?.yield(String(decoding: lineData, as: UTF8.self))
        }
        if isInputFinished, inbound.firstIndex(of: 0x0A) == nil {
            continuation?.finish()
            continuation = nil
        }
        if queuedLines >= limits.maxQueuedLines, !isReadSuspended, !isInputFinished, let readSource {
            readSource.suspend()
            isReadSuspended = true
        }
    }

    /// Stops reading (EOF, error, oversized line, close) but keeps the
    /// descriptor open so queued responses still reach a half-closed client.
    private func finishInput() {
        guard !isInputFinished else { return }
        isInputFinished = true
        resumeHangupWaiters()
        if let readSource, !isReadSuspended {
            readSource.suspend()
            isReadSuspended = true
        }
        // Lines already buffered still reach the consumer (see emitLines).
        emitLines()
    }

    private func flush() {
        while outboxOffset < outbox.count {
            let written = outbox.withUnsafeBytes { raw in
                write(descriptor, raw.baseAddress! + outboxOffset, raw.count - outboxOffset)
            }
            if written > 0 {
                outboxOffset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                armWriteSource()
                return
            }
            closeNow()
            return
        }
        outbox.removeAll(keepingCapacity: outbox.count <= 64 * 1024)
        outboxOffset = 0
        if isWriteArmed {
            writeSource?.suspend()
            isWriteArmed = false
        }
        if isCloseRequested { closeNow() }
    }

    private func armWriteSource() {
        if outboxOffset > 1 << 20, outboxOffset * 2 > outbox.count {
            outbox.removeSubrange(0..<outboxOffset)
            outboxOffset = 0
        }
        guard !isWriteArmed else { return }
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            source.setCancelHandler { [weak self] in self?.sourceCancelled() }
            writeSource = source
            liveSources += 1
        }
        isWriteArmed = true
        writeSource?.resume()
    }

    private func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        isInputFinished = true
        resumeHangupWaiters()
        continuation?.finish()
        continuation = nil
        drainTimer?.cancel()
        drainTimer = nil
        outbox = Data()
        outboxOffset = 0
        // A suspended source must be resumed before its cancel handler runs.
        if let readSource {
            if isReadSuspended { readSource.resume() }
            readSource.cancel()
        }
        if let writeSource {
            if !isWriteArmed { writeSource.resume() }
            writeSource.cancel()
        }
        readSource = nil
        writeSource = nil
        if liveSources == 0 { closeDescriptor() }
    }

    private func sourceCancelled() {
        liveSources -= 1
        if liveSources == 0, isClosed { closeDescriptor() }
    }

    private func closeDescriptor() {
        Darwin.close(descriptor)
        onClosed?()
        onClosed = nil
    }
}
