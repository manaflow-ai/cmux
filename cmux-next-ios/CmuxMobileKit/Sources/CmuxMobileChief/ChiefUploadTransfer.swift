import CmuxConversationCore
import Foundation

/// Every wait of a Chief attachment upload is bounded (Leo, 2026-11-24: "i also tried to send you a video
/// and like it just blocked me endlessly on a send"). A request that moves no bytes (the intent, the
/// commit, a part's presigned URL) has a deadline; a PUT has no deadline, since a 100 MB video on a
/// slow link takes minutes, but fails once no byte has moved for ``stall``. Each failure names its hop.
enum ChiefUpload {
    /// A PUT that sent no byte (and got no answer) for this long has stalled.
    static let stall: Duration = .seconds(30)
    /// The intent, commit, multipart completion and a part's signed URL.
    static let request: Duration = .seconds(30)
    /// Tries of one PUT (a whole small file, or one part of a large one).
    static let attempts = 3

    enum Failure: Error, CustomStringConvertible, Equatable {
        /// No byte moved for `seconds` during `hop`, after `sent` bytes of it.
        case stalled(hop: String, sent: Int64, seconds: Int)
        /// `hop` did not answer within `seconds`.
        case timedOut(hop: String, seconds: Int)

        var hop: String {
            switch self {
            case let .stalled(hop, _, _), let .timedOut(hop, _): hop
            }
        }

        var description: String {
            switch self {
            case let .stalled(hop, sent, seconds): "attachment.stalled: \(hop) sent no bytes for \(seconds) s (after \(sent) bytes)"
            case let .timedOut(hop, seconds): "attachment.timed_out: \(hop) did not answer in \(seconds) s"
            }
        }

        /// The person's text: what stopped, where, and what to do.
        var message: String {
            switch self {
            case let .stalled(hop, _, seconds):
                String(format: String(localized: "The attachment stopped uploading: nothing moved for %1$d seconds (%2$@). Try again."), seconds, hop)
            case let .timedOut(hop, seconds):
                String(format: String(localized: "The attachment couldn't upload: %1$@ didn't answer in %2$d seconds. Try again."), hop, seconds)
            }
        }
    }

    /// Whether another try of the same PUT may succeed: a stall, a dropped
    /// connection or a server error, never a refusal.
    static func isTransient(_ error: any Error) -> Bool {
        if error is Failure { return true }
        if let error = error as? URLError {
            return error.code != .cancelled && error.code != .userAuthenticationRequired
        }
        return false
    }

    /// `work`, or ``Failure/timedOut(hop:seconds:)`` once `limit` passes.
    static func bounded<T: Sendable>(_ hop: String, limit: Duration = request,
                                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw Failure.timedOut(hop: hop, seconds: Int(limit.components.seconds))
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() ?? nil else { throw CancellationError() }
            return value
        }
    }

    /// `work` (a URLSession upload that reports to `watch`), or ``Failure/stalled(hop:sent:seconds:)``
    /// once `watch` has seen no progress for `stall`. The upload is cancelled either way.
    static func watched<T: Sendable>(_ hop: String, watch: Watch, stall: Duration,
                                     _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                let tick = min(stall / 4, .seconds(1))
                while true {
                    try await Task.sleep(for: tick)
                    if watch.idle >= stall {
                        throw Failure.stalled(hop: hop, sent: watch.sent, seconds: Int(stall.components.seconds))
                    }
                }
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() ?? nil else { throw CancellationError() }
            return value
        }
    }

    /// One upload task's delegate: counts the bytes sent, when they last moved, and reports
    /// them. The answer arriving counts as movement too (a server still hashing is not a stall
    /// until it goes quiet).
    final class Watch: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var last = ContinuousClock.now
        private var bytes: Int64 = 0
        private let progress: @Sendable (Int64) -> Void

        init(progress: @escaping @Sendable (Int64) -> Void = { _ in }) {
            self.progress = progress
        }

        var idle: Duration { lock.withLock { ContinuousClock.now - last } }
        var sent: Int64 { lock.withLock { bytes } }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            lock.withLock {
                last = .now
                bytes = totalBytesSent
            }
            progress(totalBytesSent)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.withLock { last = .now }
        }
    }
}
