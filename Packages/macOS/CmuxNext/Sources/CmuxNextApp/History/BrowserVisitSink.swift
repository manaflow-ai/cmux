import CmuxNextBrowser
import CmuxNextHistory
import Foundation

/// Hands an in-memory profile history's changes to that profile's durable
/// visit log in order: one FIFO stream, drained by one task on the log's
/// actor (never on the main thread).
final class BrowserVisitSink: BrowserHistoryPersistence {
    private enum Operation: Sendable {
        case visit(String, String?, Date)
        case title(String, String)
        case remove(String)
        case clear(Date?)
        case removeHost(String)
        case barrier(CheckedContinuation<Bool, Never>)
    }

    let log: BrowserVisitLog
    private let continuation: AsyncStream<Operation>.Continuation
    private let drain: Task<Void, Never>
    /// Once a bounded queue refused an operation, this generation is never
    /// deleted during handoff: its durable state is no longer complete.
    private var droppedWrite = false

    init(log: BrowserVisitLog) {
        self.log = log
        let (stream, continuation) = AsyncStream<Operation>.makeStream(bufferingPolicy: .bufferingOldest(4_096))
        self.continuation = continuation
        // task-owner: the sink's lifetime; ends when the stream finishes in deinit
        drain = Task.detached {
            for await operation in stream {
                switch operation {
                case .visit(let url, let title, let date): await log.record(url: url, title: title, tab: nil, at: date)
                case .title(let title, let url): await log.updateTitle(title, for: url)
                case .remove(let url): await log.remove(url: url)
                case .clear(let since): await log.removeVisits(since: since)
                case .removeHost(let host): await log.remove(host: host)
                case .barrier(let barrier): barrier.resume(returning: true)
                }
            }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        continuation.finish()
    }

    func didRecordVisit(url: URL, title: String?, at date: Date) {
        enqueue(.visit(url.absoluteString, title, date))
    }

    func didUpdateTitle(_ title: String, for url: URL) {
        enqueue(.title(title, url.absoluteString))
    }

    func didRemoveEntry(for url: URL) {
        enqueue(.remove(url.absoluteString))
    }

    /// Clears visits at or after `since` (nil: all), after every queued write.
    func clear(since: Date?) {
        enqueue(.clear(since))
    }

    func remove(host: String) {
        enqueue(.removeHost(host))
    }

    /// Waits until every local history write queued before this call finished.
    func flush() async -> Bool {
        guard !droppedWrite else { return false }
        return await withCheckedContinuation { barrier in
            switch continuation.yield(.barrier(barrier)) {
            case .enqueued:
                break
            case .dropped(let dropped):
                if case .barrier(let droppedBarrier) = dropped {
                    droppedBarrier.resume(returning: false)
                }
            case .terminated:
                barrier.resume(returning: false)
            @unknown default:
                barrier.resume(returning: false)
            }
        }
    }

    private func enqueue(_ operation: Operation) {
        if case .dropped = continuation.yield(operation) {
            droppedWrite = true
        }
    }
}
