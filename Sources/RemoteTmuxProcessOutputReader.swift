import Darwin
import Foundation

/// A bounded process-pipe reader that publishes every byte written before exit.
///
/// A process termination callback is not an EOF callback: it can run before a
/// readability source has delivered the pipe's final buffered bytes. This reader
/// keeps one serial owner for the descriptor and, when told the process exited,
/// drains the nonblocking descriptor before finishing its stream.
///
/// The bounds are flow control, not a failure: once the consumer holds
/// `maxPendingChunks` unreleased chunks or `maxPendingBytes` unreleased bytes,
/// the reader stops reading the pipe and resumes when the consumer has released
/// half of either. The kernel pipe then fills and the writing process blocks, so
/// a remote that outpaces the parser is slowed down instead of disconnected.
// Sendable safety: mutable descriptor, source, and byte-accounting state is
// confined to `queue`; AsyncStream is the thread-safe handoff primitive.
final class RemoteTmuxProcessOutputReader: @unchecked Sendable {
    let stream: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let queue: DispatchQueue
    private let maxPendingChunks: Int
    private let maxPendingBytes: Int
    private let maxReadChunkBytes: Int
    private var handle: FileHandle?
    private var source: DispatchSourceRead?
    private var pendingBytes = 0
    private var pendingChunks = 0
    /// Reading stopped because the consumer is at a bound.
    private var paused = false
    private var sourceSuspended = false
    /// The process exited; reads continue until the pipe is empty, then the stream ends.
    private var draining = false
    private var closed = false
    /// One element each time reading stops at a bound, meaning the consumer has fallen a
    /// bound behind the producer. It is a stream of its own so the signal does not queue behind
    /// the backlog in ``stream``: a main-actor consumer of this stream runs at the ingest loop's
    /// next turn, before the next queued chunk is parsed.
    let pauses: AsyncStream<Void>
    private let pauseContinuation: AsyncStream<Void>.Continuation

    /// Creates a reader that holds at most `maxPendingChunks` unreleased chunks or
    /// `maxPendingBytes` unreleased bytes, reading at most `maxReadChunkBytes` at a time.
    init(
        label: String,
        maxPendingChunks: Int,
        maxPendingBytes: Int,
        maxReadChunkBytes: Int = 64 * 1024
    ) {
        // Accounting keeps at most maxPendingChunks unreleased chunks, so the
        // stream's buffer never holds more than that.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation
        (pauses, pauseContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxPendingChunks = max(1, maxPendingChunks)
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.maxReadChunkBytes = max(1, maxReadChunkBytes)
    }

    /// Starts reading `handle` on the reader's queue. The descriptor is made nonblocking.
    func attach(to handle: FileHandle) {
        let fileDescriptor = handle.fileDescriptor
        queue.async { [weak self] in
            guard let self, !self.closed, self.source == nil else { return }
            self.handle = handle
            self.makeNonblocking(fileDescriptor)
            let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: self.queue)
            source.setEventHandler { [weak self] in
                self?.readAvailable(from: fileDescriptor)
            }
            self.source = source
            source.resume()
        }
    }

    /// Returns a chunk's share of the bounds once the consumer is done with it.
    func release(_ data: Data) {
        let byteCount = data.count
        queue.async { [weak self] in
            self?.releaseOnQueue(byteCount: byteCount)
        }
    }

    /// Drains bytes already committed to the pipe, then finishes the stream.
    func processDidExit() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            // The drain owns reads from here on; a readability source left
            // running would fire without pause while the drain waits on the
            // consumer.
            self.draining = true
            self.setSourceSuspended(true)
            self.drain()
        }
    }

    /// Cancels the reader without promising delivery of unread bytes.
    func close() {
        queue.async { [weak self] in
            self?.finishOnQueue()
        }
    }

    /// Sets `O_NONBLOCK`, so the post-exit drain can tell an empty pipe from a slow writer.
    private func makeNonblocking(_ fileDescriptor: Int32) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    private var atBound: Bool {
        pendingChunks >= maxPendingChunks || pendingBytes >= maxPendingBytes
    }

    /// Read-source handler: reads one chunk, or pauses when the consumer is at a bound.
    private func readAvailable(from fileDescriptor: Int32) {
        guard !closed, !draining, let source else { return }
        guard !atBound else {
            pause()
            return
        }
        if readAndPublish(from: fileDescriptor, byteCount: readByteCount(available: source.data)) == .ended {
            finishOnQueue()
        }
    }

    /// Reads until the pipe is empty after the process exited, pausing at a bound like the
    /// read source does; a release resumes it.
    private func drain() {
        guard !closed, let handle else {
            finishOnQueue()
            return
        }
        let fileDescriptor = handle.fileDescriptor
        while !closed {
            guard !atBound else {
                pause()
                return
            }
            switch readAndPublish(from: fileDescriptor, byteCount: readByteCount(available: UInt(maxReadChunkBytes))) {
            case .published, .interrupted:
                continue
            case .wouldBlock, .ended:
                finishOnQueue()
            }
        }
    }

    /// Reads up to `byteCount` bytes and yields them as one chunk, counting it against the bounds.
    private func readAndPublish(
        from fileDescriptor: Int32,
        byteCount: Int
    ) -> RemoteTmuxPipeReadResult {
        var buffer = [UInt8](repeating: 0, count: max(1, byteCount))
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead > 0 {
            let chunk = Data(buffer[0..<bytesRead])
            pendingBytes += chunk.count
            pendingChunks += 1
            if case .terminated = continuation.yield(chunk) { return .ended }
            return .published
        }
        if bytesRead == 0 { return .ended }
        if errno == EINTR { return .interrupted }
        if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
        return .ended
    }

    /// A read never takes more than the byte bound has room for, so one large
    /// write cannot overshoot it.
    private func readByteCount(available: UInt) -> Int {
        let room = maxPendingBytes - pendingBytes
        guard available > 0 else { return 1 }
        return max(1, min(maxReadChunkBytes, room, Int(min(available, UInt(maxReadChunkBytes)))))
    }

    /// Returns a chunk's share of the bounds and resumes reading once the consumer is at half.
    private func releaseOnQueue(byteCount: Int) {
        pendingBytes = max(0, pendingBytes - byteCount)
        pendingChunks = max(0, pendingChunks - 1)
        guard paused, !closed,
              pendingChunks <= maxPendingChunks / 2,
              pendingBytes <= maxPendingBytes / 2 else { return }
        paused = false
        if draining {
            drain()
        } else {
            setSourceSuspended(false)
        }
    }

    /// Stops reading until the consumer releases half of what it holds.
    private func pause() {
        guard !paused else { return }
        paused = true
        pauseContinuation.yield()
        setSourceSuspended(true)
    }

    /// Suspends or resumes the read source, keeping dispatch's suspend count balanced.
    private func setSourceSuspended(_ suspended: Bool) {
        guard let source, suspended != sourceSuspended else { return }
        sourceSuspended = suspended
        if suspended { source.suspend() } else { source.resume() }
    }

    /// Cancels the read source and ends the stream. Safe to call more than once.
    private func finishOnQueue() {
        guard !closed else { return }
        closed = true
        pendingBytes = 0
        pendingChunks = 0
        let sourceToCancel = source
        sourceToCancel?.cancel()
        // Dispatch traps when a suspended source is released, and a cancelled
        // source delivers no further events once resumed.
        setSourceSuspended(false)
        source = nil
        handle = nil
        continuation.finish()
        pauseContinuation.finish()
    }
}
