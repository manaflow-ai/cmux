#if canImport(Darwin)
public import Dispatch
public import Foundation

/// The one way a store writes a file that changes often: a caller hands over a value and returns at
/// once, and one background queue writes the newest value of each path after a short window, so a
/// burst of changes costs one disk write instead of one per change. macOS reports a process that
/// writes more than its disk-write budget (the "resource: disk writes" hang-watch reports, cmuxterm-hq
/// hq#11120, #13152), and a whole-file save per change, or a log line per event, is how an app
/// exceeds it.
///
/// - Latest wins: a pending write of a path is replaced by a newer one; the older one never runs.
/// - Bounded: replaced writes keep the queue at one pending write per path; past
///   ``maximumQueuedBytes`` of pending bytes the window is skipped and the queue drains at once
///   (nothing is dropped, and the caller still never waits); an append stream keeps at most
///   ``maximumAppendBytes`` pending per path, dropping its oldest lines.
/// - Off the caller's thread: ``save(to:options:bytes:then:produce:)`` and ``append(_:to:rotatingTo:limit:)``
///   take the lock for a dictionary update, never the disk.
/// - ``flush()`` (app termination) and ``settled()`` (awaiting, holding no thread) run what is
///   pending now. A crash between a call and its write loses that write: at most one window, plus
///   the queue's backlog.
///
/// Do not use it where the caller needs the bytes on disk before going on (a write whose failure is
/// reported to the person, a file a child process is about to read): those keep a direct write.
public nonisolated final class CoalescingFileWriter: Sendable {
    public static let defaultWindow: TimeInterval = 0.25
    public static let defaultMaximumQueuedBytes = 32 * 1024 * 1024
    public static let maximumAppendBytes = 1024 * 1024

    /// One file ring step for an append stream: when a write would take the file past `limit`, the
    /// full file becomes `older` (replacing it) and the lines start a new one.
    struct Rotation: Sendable {
        var older: URL
        var limit: UInt64
    }

    private enum Work: Sendable {
        case replace(produce: @Sendable () throws -> Data?, options: Data.WritingOptions, then: (@Sendable () -> Void)?)
        case append(chunks: [Data], rotation: Rotation?)
    }

    private struct Job: Sendable {
        var url: URL
        var work: Work
        var bytes: Int
    }

    private struct State: Sendable {
        var jobs: [String: Job] = [:]
        var order: [String] = []
        var pendingBytes = 0
        var armed = false
        /// Jobs pending or running: a path with a job counts once.
        var busy = 0
        var diskWrites = 0
        var replaced = 0
        var droppedAppendBytes = 0
    }

    private let queue: DispatchQueue
    private let window: TimeInterval
    private let maximumQueuedBytes: Int
    private let onError: @Sendable (URL, any Error) -> Void
    private let state = Mutex<State>(State())

    /// - Parameters:
    ///   - queue: The serial queue the writes run on; a store that also reads on one passes its own,
    ///     so a read queued after ``flushNow()`` sees the write. A new utility queue when nil.
    ///   - window: How long a first pending write waits for newer ones.
    ///   - maximumQueuedBytes: The pending bytes past which the queue drains without waiting.
    ///   - onError: Told when a write failed (the file keeps what it had).
    public init(queue: DispatchQueue? = nil, window: TimeInterval = CoalescingFileWriter.defaultWindow,
                maximumQueuedBytes: Int = CoalescingFileWriter.defaultMaximumQueuedBytes,
                onError: @escaping @Sendable (URL, any Error) -> Void = { _, _ in }) {

        self.queue = queue ?? DispatchQueue(label: "com.cmuxterm.app.next.coalescing-file-writer", qos: .utility)
        self.window = window
        self.maximumQueuedBytes = maximumQueuedBytes
        self.onError = onError
    }

    /// Writes `data` to `url` (latest wins).
    public func write(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) {
        save(to: url, options: options, bytes: data.count) { data }
    }

    /// Writes what `produce` returns to `url` on the queue (latest wins): nil removes the file, a
    /// throw keeps it as it is. `then` runs on the queue after a write that ran.
    ///
    /// - Parameters:
    ///   - bytes: The size `produce` will return, if known, for the queued-bytes bound.
    public func save(to url: URL, options: Data.WritingOptions = [.atomic], bytes: Int = 0,
                      then: (@Sendable () -> Void)? = nil, produce: @escaping @Sendable () throws -> Data?) {
        enqueue(Job(url: url, work: .replace(produce: produce, options: options, then: then), bytes: bytes))
    }

    /// Appends `data` to `url` with the other lines pending for it, in one write. With `rotatingTo`,
    /// a write that would take the file past `limit` first moves it there.
    public func append(_ data: Data, to url: URL, rotatingTo older: URL? = nil, limit: UInt64 = .max) {
        let rotation = older.map { Rotation(older: $0, limit: limit) }
        enqueue(Job(url: url, work: .append(chunks: [data], rotation: rotation), bytes: data.count))
    }

    /// Whether any write is pending or running.
    public var isBusy: Bool { state.withLock { $0.busy > 0 } }

    /// How many writes reached the disk (tests, measurement).
    public var diskWrites: Int { state.withLock { $0.diskWrites } }

    /// How many pending writes a newer one replaced (tests, measurement).
    public var replacedWrites: Int { state.withLock { $0.replaced } }

    /// Starts running what is pending without waiting for the window, and returns at once.
    public func flushNow() {
        guard state.withLock({ !$0.jobs.isEmpty }) else { return }
        queue.async { [self] in drain() }
    }

    /// Drops what is pending (a folder about to be removed must not be recreated by a late write).
    public func discardPending() {
        state.withLock { state in
            state.busy -= state.jobs.count
            state.jobs = [:]
            state.order = []
            state.pendingBytes = 0
        }
    }

    /// Returns, holding no thread, once everything pending before this call has run.
    public func settled() async {
        flushNow()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// Runs everything pending now and waits for it: for app termination, under its deadline.
    public func flush() {
        // concurrency-allow: termination only, after the quit deadline is armed; never from the writer's own queue
        queue.blockingSync { drain() }
    }

    private func enqueue(_ job: Job) {
        let key = job.url.standardizedFileURL.path
        let (arm, overBound) = state.withLock { state -> (Bool, Bool) in
            if var old = state.jobs[key] {
                state.pendingBytes -= old.bytes
                switch (old.work, job.work) {
                case (.append(var chunks, let rotation), .append(let added, _)):
                    chunks += added
                    var bytes = old.bytes + job.bytes
                    // Lines past the bound: the oldest go, so a stalled disk never grows memory.
                    while bytes > Self.maximumAppendBytes, chunks.count > 1 {
                        let dropped = chunks.removeFirst()
                        bytes -= dropped.count
                        state.droppedAppendBytes += dropped.count
                    }
                    old.work = .append(chunks: chunks, rotation: rotation)
                    old.bytes = bytes
                    state.jobs[key] = old
                    state.pendingBytes += bytes
                default:
                    state.jobs[key] = job
                    state.pendingBytes += job.bytes
                    state.replaced += 1
                }
            } else {
                state.jobs[key] = job
                state.order.append(key)
                state.pendingBytes += job.bytes
                state.busy += 1
            }
            let arm = !state.armed
            state.armed = true
            return (arm, state.pendingBytes > maximumQueuedBytes)
        }
        if overBound {
            queue.async { [self] in drain() }
        } else if arm {
            // concurrency-allow: the window's one-shot deadline runs drain() on the writer's own serial queue
            // (a utility queue, or the store's background queue), never the main thread; CmuxNextCompat sits
            // below CmuxNextWakeups, so DemandTimer is out of reach here, and one deadline per burst is not a poll
            queue.asyncAfter(deadline: .now() + window) { [self] in drain() }
        }
    }

    /// On the queue only.
    private func drain() {
        let batch = state.withLock { state -> [Job] in
            state.armed = false
            let batch = state.order.compactMap { state.jobs[$0] }
            state.jobs = [:]
            state.order = []
            state.pendingBytes = 0
            return batch
        }
        for job in batch {
            perform(job)
            state.withLock { $0.busy -= 1 }
        }
    }

    private func perform(_ job: Job) {
        do {
            switch job.work {
            case .replace(let produce, let options, let then):
                guard let data = try produce() else {
                    try? FileManager.checked.removeItem(at: job.url)
                    state.withLock { $0.diskWrites += 1 }
                    return
                }
                try data.blockingWrite(to: job.url, options: options)
                state.withLock { $0.diskWrites += 1 }
                then?()
            case .append(let chunks, let rotation):
                let files = FileManager.checked
                try files.createDirectory(at: job.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !files.fileExists(atPath: job.url.path) { _ = files.createFile(atPath: job.url.path, contents: nil) }
                let added = chunks.reduce(Data(), +)
                let handle = try FileHandle(forWritingTo: job.url)
                let size = try handle.seekToEnd()
                if let rotation, size > 0, size + UInt64(added.count) > rotation.limit {
                    try handle.close()
                    try? files.removeItem(at: rotation.older)
                    try files.moveItem(at: job.url, to: rotation.older)
                    _ = files.createFile(atPath: job.url.path, contents: added)
                } else {
                    try handle.write(contentsOf: added)
                    try handle.close()
                }
                state.withLock { $0.diskWrites += 1 }
            }
        } catch {
            onError(job.url, error)
        }
    }
}
#endif
