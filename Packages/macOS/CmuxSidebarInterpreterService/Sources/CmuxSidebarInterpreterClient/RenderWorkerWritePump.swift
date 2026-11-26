import Dispatch
import Foundation

/// Serial blocking-I/O bridge for one render-worker generation.
///
/// `LengthPrefixedMessageChannel` intentionally uses blocking POSIX writes.
/// Those writes must never execute on `RenderWorkerClient`'s actor executor:
/// a full child pipe would otherwise prevent that same actor's deadlines from
/// terminating the child and making the pipe writable again.
///
/// `@unchecked Sendable` is safe because every mutable mailbox field is
/// protected by `stateLock`. A synchronous lock is intentional at this
/// low-level bridge: actor-hopping each enqueue would make the supervising
/// actor reentrant and break its strict replay/message ordering.
final class RenderWorkerWritePump: @unchecked Sendable {
    private typealias PendingWrite = (
        outbound: RenderWorkerOutboundWrite,
        onFailure: @Sendable () -> Void
    )
    private typealias ScheduledWrite = (
        token: UInt64,
        outbound: RenderWorkerOutboundWrite,
        onFailure: @Sendable () -> Void
    )

    static let maximumRetainedMessageCount = 64
    static let maximumRetainedBytes = LengthPrefixedMessageChannel.maximumFrameLength

    private let channel: LengthPrefixedMessageChannel
    private let writeTimeout: TimeInterval
    private let writerQueue: DispatchQueue
    private let deadlineQueue: DispatchQueue
    // Lock carve-out: short synchronous mailbox bookkeeping shared by the
    // supervising actor, blocking writer, and independent deadline queue.
    private let stateLock = NSLock()
    private var pending: [PendingWrite] = []
    private var retainedMessageCount = 0
    private var retainedByteCount = 0
    private var nextWriteToken: UInt64 = 0
    private var activeWriteToken: UInt64?
    private var activeWriteByteCount = 0
    private var writeDeadline: DispatchSourceTimer?
    private var cancelled = false
    private var failed = false

    init(
        channel: LengthPrefixedMessageChannel,
        generation: Int,
        writeTimeout: Duration = .seconds(3)
    ) {
        self.channel = channel
        let components = writeTimeout.components
        self.writeTimeout = max(
            0.001,
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        )
        writerQueue = DispatchQueue(
            label: "com.cmuxterm.sidebar-render-writer.\(generation)",
            qos: .userInitiated
        )
        deadlineQueue = DispatchQueue(
            label: "com.cmuxterm.sidebar-render-writer-deadline.\(generation)",
            qos: .userInitiated
        )
    }

    @discardableResult
    func enqueue(
        _ outbound: RenderWorkerOutboundWrite,
        onFailure: @escaping @Sendable () -> Void
    ) -> Bool {
        var accepted = false
        var shouldFail = false
        var timerToCancel: DispatchSourceTimer?
        var scheduled: ScheduledWrite?

        stateLock.withLock {
            guard !cancelled, !failed else { return }

            let outbound = coalescedOutboundLocked(outbound)
            guard retainedMessageCount < Self.maximumRetainedMessageCount,
                  retainedByteCount <= Self.maximumRetainedBytes - outbound.data.count else {
                failed = true
                pending.removeAll(keepingCapacity: false)
                retainedMessageCount = activeWriteToken == nil ? 0 : 1
                retainedByteCount = activeWriteByteCount
                timerToCancel = writeDeadline
                writeDeadline = nil
                shouldFail = true
                return
            }

            pending.append((outbound, onFailure))
            retainedMessageCount += 1
            retainedByteCount += outbound.data.count
            accepted = true
            scheduled = dequeueNextWriteLocked()
        }

        timerToCancel?.cancel()
        if shouldFail {
            onFailure()
        } else if let scheduled {
            schedule(scheduled)
        }
        return accepted
    }

    func cancel() {
        let timer = stateLock.withLock {
            guard !cancelled else { return nil as DispatchSourceTimer? }
            cancelled = true
            pending.removeAll(keepingCapacity: false)
            retainedMessageCount = activeWriteToken == nil ? 0 : 1
            retainedByteCount = activeWriteByteCount
            let timer = writeDeadline
            writeDeadline = nil
            return timer
        }
        timer?.cancel()
    }

    private func coalescedOutboundLocked(
        _ newer: RenderWorkerOutboundWrite
    ) -> RenderWorkerOutboundWrite {
        guard let key = newer.coalescingKey else { return newer }
        let replacementIndex: Int?
        switch key {
        case .scene, .geometry:
            replacementIndex = pending.lastIndex {
                $0.outbound.coalescingKey == key
            }
        case .drag, .scroll:
            replacementIndex = pending.indices.last.flatMap { index in
                pending[index].outbound.coalescingKey == key ? index : nil
            }
        }
        guard let replacementIndex else { return newer }

        let removed = pending.remove(at: replacementIndex)
        retainedMessageCount -= 1
        retainedByteCount -= removed.outbound.data.count
        return removed.outbound.coalescing(with: newer) ?? newer
    }

    /// Called only while `stateLock` is held.
    private func dequeueNextWriteLocked() -> ScheduledWrite? {
        guard !cancelled,
              !failed,
              activeWriteToken == nil,
              !pending.isEmpty else {
            return nil
        }

        let next = pending.removeFirst()
        nextWriteToken &+= 1
        activeWriteToken = nextWriteToken
        activeWriteByteCount = next.outbound.data.count
        return (nextWriteToken, next.outbound, next.onFailure)
    }

    private func schedule(_ scheduled: ScheduledWrite) {
        // Genuine one-shot I/O deadline on a different queue: it must be able
        // to fire while `writerQueue` is parked inside write(2).
        let timer = DispatchSource.makeTimerSource(queue: deadlineQueue)
        timer.schedule(deadline: .now() + writeTimeout)
        timer.setEventHandler { [weak self] in
            self?.writeDeadlineExpired(scheduled)
        }

        let shouldStart = stateLock.withLock {
            guard activeWriteToken == scheduled.token, !cancelled, !failed else {
                return false
            }
            writeDeadline?.cancel()
            writeDeadline = timer
            return true
        }

        timer.activate()
        guard shouldStart else {
            timer.cancel()
            return
        }

        writerQueue.async { [weak self, channel] in
            let succeeded: Bool
            do {
                try channel.sendMessage(scheduled.outbound.data)
                succeeded = true
            } catch {
                succeeded = false
            }
            self?.finishedWrite(scheduled, succeeded: succeeded)
        }
    }

    private func finishedWrite(
        _ completed: ScheduledWrite,
        succeeded: Bool
    ) {
        var timerToCancel: DispatchSourceTimer?
        var shouldFail = false
        var scheduled: ScheduledWrite?

        stateLock.withLock {
            guard activeWriteToken == completed.token else { return }
            timerToCancel = writeDeadline
            writeDeadline = nil
            activeWriteToken = nil
            retainedMessageCount -= 1
            retainedByteCount -= activeWriteByteCount
            activeWriteByteCount = 0

            guard !cancelled, !failed else { return }
            if succeeded {
                scheduled = dequeueNextWriteLocked()
            } else {
                failed = true
                pending.removeAll(keepingCapacity: false)
                retainedMessageCount = 0
                retainedByteCount = 0
                shouldFail = true
            }
        }

        timerToCancel?.cancel()
        if shouldFail {
            completed.onFailure()
        } else if let scheduled {
            schedule(scheduled)
        }
    }

    private func writeDeadlineExpired(_ expired: ScheduledWrite) {
        let shouldFail = stateLock.withLock {
            guard activeWriteToken == expired.token, !cancelled, !failed else {
                return false
            }
            failed = true
            pending.removeAll(keepingCapacity: false)
            retainedMessageCount = 1
            retainedByteCount = activeWriteByteCount
            writeDeadline = nil
            return true
        }
        if shouldFail {
            expired.onFailure()
        }
    }
}
