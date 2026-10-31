import CmuxNextCompat
public import Foundation

/// Writes one small state file off the main thread, latest wins.
///
/// A main-actor owner (a new chat's unsent drafts, each chat's scroll place) hands each change to
/// ``save(_:)`` as a closure over a value snapshot; the encode and the write run on `BackgroundWork`'s
/// files lane at ``WorkPriority/bestEffort`` and block shutdown, so the quit, which awaits
/// `BackgroundWork.shutdown()`, keeps the last one. Saves that arrive while one is written collapse into
/// the newest: at most one write runs and one waits, whatever the rate of changes, and writes land in the
/// order of their saves. The main thread never touches the disk (threading-model.md: the main thread never
/// blocks).
///
/// ```swift
/// let writer = StateFileWriter(file: url, work: work)
/// writer.save { [drafts] in drafts.isEmpty ? nil : try JSONEncoder().encode(drafts) }   // nil removes the file
/// ```
public nonisolated final class StateFileWriter: Sendable {
    /// Puts the bytes at the URL atomically, or removes the file for nil. Runs on a lane thread.
    public typealias Write = @Sendable (URL, Data?) -> Void
    /// The file's next contents: bytes, or nil to remove the file. A throw skips that save.
    public typealias Contents = @Sendable () throws -> Data?

    /// The file this writer owns.
    public let file: URL
    private let work: BackgroundWork
    private let write: Write
    // concurrency-allow: the newest pending save and the waiters of flushed(), taken from the main actor and the lane thread that must not await (lock carve-out: a short critical section, no I/O under it).
    private let state = Mutex(State())

    private struct State {
        var pending: Contents?
        var running = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// The disk: an atomic write through the checked seam, or a remove.
    public static let disk: Write = { url, data in
        if let data {
            try? data.blockingWrite(to: url, options: .atomic)
        } else {
            try? FileManager.checked.removeItem(at: url)
        }
    }

    /// - Parameters:
    ///   - file: The state file.
    ///   - work: The app's blocking-work lanes (`AppServices.work`); tests pass their own.
    ///   - write: Puts each save on disk; default ``disk`` (tests record where it runs).
    public init(file: URL, work: BackgroundWork, write: @escaping Write = StateFileWriter.disk) {
        self.file = file
        self.work = work
        self.write = write
    }

    /// Queues `contents` as the file's next state, replacing a save that has not started; returns at once.
    public func save(_ contents: @escaping Contents) {
        let start = state.withLock { state -> Bool in
            state.pending = contents
            defer { state.running = true }
            return !state.running
        }
        guard start else { return }
        // blockShutdown: the lanes take it even after shutdown began, and the quit waits for it.
        work.post(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { [self] in drain() }
    }

    /// Returns once every save queued before the call is on disk. The caller suspends; no thread waits.
    public func flushed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state -> Bool in
                if state.running { state.waiters.append(continuation) }
                return !state.running
            }
            if idle { continuation.resume() }
        }
    }

    /// Writes the newest save until none is left, then ends this run and wakes the waiters.
    private func drain() {
        repeat {
            while let next = state.withLock({ state -> Contents? in
                defer { state.pending = nil }
                return state.pending
            }) {
                let data: Data?
                do { data = try next() } catch { continue }
                write(file, data)
            }
        } while !finished()
    }

    /// Ends this run unless a save came in after the last take (the drain then takes it); wakes the waiters.
    private func finished() -> Bool {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>]? in
            guard state.pending == nil else { return nil }
            state.running = false
            defer { state.waiters = [] }
            return state.waiters
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume() }
        return true
    }
}
