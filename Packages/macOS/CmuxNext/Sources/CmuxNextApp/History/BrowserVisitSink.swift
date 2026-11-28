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
    }

    let log: BrowserVisitLog
    private let continuation: AsyncStream<Operation>.Continuation
    private let drain: Task<Void, Never>

    init(log: BrowserVisitLog) {
        self.log = log
        let (stream, continuation) = AsyncStream<Operation>.makeStream(bufferingPolicy: .bufferingNewest(4_096))
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
                }
            }
        }
    }

    deinit {
        continuation.finish()
    }

    func didRecordVisit(url: URL, title: String?, at date: Date) {
        continuation.yield(.visit(url.absoluteString, title, date))
    }

    func didUpdateTitle(_ title: String, for url: URL) {
        continuation.yield(.title(title, url.absoluteString))
    }

    func didRemoveEntry(for url: URL) {
        continuation.yield(.remove(url.absoluteString))
    }

    /// Clears visits at or after `since` (nil: all), after every queued write.
    func clear(since: Date?) {
        continuation.yield(.clear(since))
    }

    func remove(host: String) {
        continuation.yield(.removeHost(host))
    }
}
