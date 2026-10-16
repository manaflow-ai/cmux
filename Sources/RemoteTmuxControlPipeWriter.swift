import Foundation

/// Bounded off-main writer for the SSH control client's stdin pipe.
///
/// `RemoteTmuxControlConnection` records command FIFO entries on the main actor
/// before this writer can emit bytes, so tmux `%begin`/`%end` replies cannot
/// outrun their local correlation slot. The write itself may block on a stalled
/// SSH pipe; keeping it on this serial queue prevents that from freezing UI.
///
/// The writer refuses a payload only when the pipe has stopped taking bytes. A
/// full queue on a pipe that is still draining is a slow link or a big burst,
/// both of which finish on their own; tearing the stream down for it made a
/// host with many sessions reconnect on every attach. Two things count as
/// stopped: the oldest unwritten bytes have waited ``stallLimit`` without any
/// write returning, or the unwritten total passes the memory ceiling.
@MainActor
final class RemoteTmuxControlPipeWriter {
    /// How long the pipe may go without taking any bytes, while some are waiting,
    /// before the writer reports it dead. tmux reads its control input as fast as
    /// it arrives, so a write that cannot finish for this long means the transport
    /// is not delivering anything.
    nonisolated static let defaultStallLimit: Duration = .seconds(30)

    private let handle: FileHandle
    private let queue: DispatchQueue
    private let ledger: Ledger
    private let onFailure: @MainActor @Sendable () -> Void
    /// Called on the write queue after each write returns and its bytes are released. The
    /// connection passes nil; an observer can use it to wait on the pipe instead of on time.
    private let onWriteFinished: (@Sendable () -> Void)?
    private var closed = false

    init(
        handle: FileHandle,
        label: String,
        maxPendingBytes: Int,
        stallLimit: Duration = RemoteTmuxControlPipeWriter.defaultStallLimit,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        onWriteFinished: (@Sendable () -> Void)? = nil,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        self.handle = handle
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.ledger = Ledger(ceiling: maxPendingBytes, stallLimit: stallLimit, now: now)
        self.onWriteFinished = onWriteFinished
        self.onFailure = onFailure
    }

    /// Bytes handed to the queue that the pipe has not taken yet.
    var unwrittenBytes: Int { ledger.unwrittenBytes }

    /// Queues `data` behind every earlier payload. Returns false when the pipe has
    /// stopped taking bytes (see the type comment) or the writer is closed; the
    /// caller then reconnects.
    func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard !closed, ledger.admit(data.count) else { return false }

        let ledger = self.ledger
        queue.async { [weak self, handle, data, onWriteFinished] in
            var didFail = false
            do {
                try handle.write(contentsOf: data)
            } catch {
                didFail = true
            }
            // Released here, where the write returned, not on the main actor: a
            // long main-actor turn (the attach of a host with many windows) would
            // otherwise keep counting bytes the pipe already took.
            ledger.release(data.count)
            onWriteFinished?()
            guard didFail else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.onFailure()
            }
        }
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        queue.async { [handle] in
            try? handle.close()
        }
    }

    /// Unwritten-byte accounting shared by the main actor (admit) and the write
    /// queue (release).
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private let ceiling: Int
        private let stallLimit: Duration
        private let now: @Sendable () -> ContinuousClock.Instant
        private var unwritten = 0
        /// When the pipe last made progress while bytes were waiting: the moment
        /// bytes started waiting on an idle writer, or the last write that returned.
        private var progressAt: ContinuousClock.Instant?

        init(ceiling: Int, stallLimit: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant) {
            self.ceiling = ceiling
            self.stallLimit = stallLimit
            self.now = now
        }

        var unwrittenBytes: Int {
            lock.lock(); defer { lock.unlock() }
            return unwritten
        }

        /// Checked on each new payload, which is the moment anything is waiting on
        /// the pipe; with nothing new to send there is nothing to time out.
        func admit(_ count: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let instant = now()
            if unwritten > 0, let progressAt, progressAt.duration(to: instant) >= stallLimit {
                return false
            }
            guard count <= ceiling - unwritten else { return false }
            if unwritten == 0 { progressAt = instant }
            unwritten += count
            return true
        }

        func release(_ count: Int) {
            lock.lock(); defer { lock.unlock() }
            unwritten = max(0, unwritten - count)
            progressAt = unwritten > 0 ? now() : nil
        }
    }
}
