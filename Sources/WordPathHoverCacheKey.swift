import CoreGraphics
import Foundation
import os

/// Identifies the visible terminal cell whose command-hover resolution is cached.
///
/// Command-click routing deliberately resolves again, so terminal output changing
/// under a stationary pointer cannot open stale data.
struct WordPathHoverCacheKey: Equatable, Sendable {
    let surfaceID: UUID
    let surfaceGeneration: UInt64
    let row: Int
    let column: Int
    let rows: Int
    let columns: Int
    let boundsSize: CGSize
    let cellSize: CGSize
    let workingDirectory: String
}

/// Cooperative cancellation for command-hover filesystem probes.
///
/// A mounted filesystem call can remain blocked after cancellation. The
/// process-wide probe pool bounds that case to one worker, while this signal
/// stops candidate iteration as soon as the blocked call returns.
final class WordPathHoverFilesystemProbeCancellation: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCancelled: Bool {
        state.withLock { $0 }
    }

    func cancel() {
        state.withLock { $0 = true }
    }
}

/// Runs command-hover filesystem work with a process-wide concurrency bound.
///
/// Only one probe runs and only the latest waiting probe is retained. This
/// keeps a slow or unavailable mounted filesystem from accumulating blocked
/// workers as terminal views are closed and recreated.
final class WordPathHoverFilesystemProbePool: @unchecked Sendable {
    struct Job: Sendable {
        let id: UUID
        let run: @Sendable () -> Void
        let discarded: @Sendable () -> Void
    }

    static let shared = WordPathHoverFilesystemProbePool()

    private struct State {
        var runningID: UUID?
        var pending: Job?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue: DispatchQueue

    init(label: String = "com.cmux.command-hover-filesystem-probe") {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func submit(_ job: Job) {
        let transition = state.withLock { state -> (start: Job?, discarded: Job?) in
            if state.runningID == nil {
                state.runningID = job.id
                return (job, nil)
            }

            let discarded = state.pending
            state.pending = job
            return (nil, discarded)
        }

        transition.discarded?.discarded()
        if let job = transition.start {
            execute(job)
        }
    }

    func cancelPending(id: UUID) {
        let discarded = state.withLock { state -> Job? in
            guard state.pending?.id == id else { return nil }
            defer { state.pending = nil }
            return state.pending
        }
        discarded?.discarded()
    }

    private func execute(_ job: Job) {
        queue.async { [self] in
            job.run()

            let next = state.withLock { state -> Job? in
                guard state.runningID == job.id else { return nil }
                let next = state.pending
                state.pending = nil
                state.runningID = next?.id
                return next
            }
            if let next {
                execute(next)
            }
        }
    }
}
