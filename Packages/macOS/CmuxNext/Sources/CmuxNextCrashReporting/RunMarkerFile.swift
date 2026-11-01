import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Dispatch
public import Foundation

/// Writes `run.json` for `AppRunMarker` on a serial background queue, so
/// the main thread never waits on the disk.
///
/// - Coalesced: a write that is still queued is replaced by a newer one, and
///   bytes equal to what is already on disk are not written again.
/// - The bytes are made on the queue (`submit(encoding:)`): making them reads
///   the crash context's footprint, a system call the main thread never makes.
/// - Atomic without fsync: a temporary file in the same folder, then
///   rename(2). The marker only has to survive the end of this process
///   (SIGKILL, a crash): data in the kernel's file cache does. Only a power
///   loss can lose it, and then the next launch shows the restart notice,
///   which is right. `Data.write(options: .atomic)` also fsyncs, which waits
///   for the device and blocked the main thread for up to about 1 s on a
///   busy disk.
/// - `written(_:timeout:)` lets the quit path await one write with a
///   deadline (no sleep: a continuation resumed by the write, or by a
///   one-shot `DemandTimer`).
public nonisolated final class RunMarkerFile: Sendable {
    /// Writes the bytes to the file (tests pass a fake).
    public typealias Writer = @Sendable (Data, URL) throws -> Void
    /// Makes the bytes to write; nil when they cannot be made (nothing is written).
    public typealias Encode = @Sendable () -> Data?

    /// `run.json`.
    public let url: URL
    /// The signal handler's marker next to it, removed with it at a clean exit.
    public let signalURL: URL
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.run-marker", qos: .utility)
    private let writer: Writer
    private let state = Mutex(State())
    /// Held for one disk write and for close's unlinks, never while bytes are made: close waits for at most one
    /// in-flight write, never for an encode (which reads the kernel), and no write lands after the unlinks.
    // concurrency-allow: held only for one write of about 100 bytes (no fsync) or two unlinks, at exit.
    private let fileLock = Mutex(())

    private struct Waiter {
        var id: UInt64
        var ticket: UInt64
        var continuation: CheckedContinuation<Bool, Never>
    }

    private struct State {
        /// The newest bytes asked for (made on the queue) and their ticket; nil once a drain took them.
        var latest: Encode?
        var latestTicket: UInt64 = 0
        /// The bytes on disk and the newest ticket they satisfy.
        var written: Data?
        var completed: UInt64 = 0
        var closed = false
        var nextWaiter: UInt64 = 0
        var waiters: [Waiter] = []
        /// Disk writes done (tests).
        var writes = 0
    }

    /// The marker at `url` with its signal marker at `signalURL`, written by `writer`.
    public init(url: URL, signalURL: URL, writer: @escaping Writer = RunMarkerFile.replaceAtomically) {
        self.url = url
        self.signalURL = signalURL
        self.writer = writer
    }

    /// Asks for `data` on disk; returns at once. The ticket is satisfied
    /// once these bytes, or newer ones, are written.
    @discardableResult
    public func submit(_ data: Data) -> UInt64 {
        submit(encoding: { data })
    }

    /// Asks for the bytes `encode` makes on disk; returns at once. `encode` runs on the writer queue, never on
    /// the caller's thread: making the bytes may read the kernel (the marker's footprint). A newer submit
    /// replaces one whose bytes are not made yet. The ticket is satisfied once these bytes, or newer ones, are
    /// written.
    @discardableResult
    public func submit(encoding encode: @escaping Encode) -> UInt64 {
        let ticket: UInt64? = state.withLock { state in
            guard !state.closed else { return nil }
            state.latestTicket &+= 1
            state.latest = encode
            return state.latestTicket
        }
        guard let ticket else { return 0 }
        queue.async { self.drain() }
        return ticket
    }

    /// True once `ticket` is on disk; false when `timeout` passes first.
    /// After `close` it answers true: the file was removed on purpose.
    public func written(_ ticket: UInt64, timeout: Duration) async -> Bool {
        let deadline = DemandTimer(owner: "run-marker.write")
        defer { deadline.cancel() }
        return await withCheckedContinuation { continuation in
            let id: UInt64? = state.withLock { state in
                if state.closed || state.completed >= ticket { return nil }
                state.nextWaiter &+= 1
                state.waiters.append(Waiter(id: state.nextWaiter, ticket: ticket, continuation: continuation))
                return state.nextWaiter
            }
            guard let id else { return continuation.resume(returning: true) }
            deadline.schedule(after: timeout) { [weak self] in self?.expire(id) }
        }
    }

    /// Removes `run.json` and `run.signal` after any write in progress, and
    /// writes nothing more (a normal quit). Called at exit: it waits for at
    /// most one in-flight write of about 100 bytes without fsync.
    public func close() {
        let waiters = state.withLock { state in
            state.closed = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.continuation.resume(returning: true) }
        // At exit only: waits for at most one in-flight write (no fsync), never for bytes being made.
        fileLock.withLock { _ in
            unlink(url.path)
            unlink(signalURL.path)
        }
    }

    /// Disk writes done so far (tests).
    public var writeCount: Int { state.withLock { $0.writes } }

    /// Returns once every drain queued before the call has run (tests).
    public func drained() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    private func drain() {
        let job: (Encode, UInt64)? = state.withLock { state in
            guard !state.closed, let latest = state.latest else { return nil }
            state.latest = nil
            return (latest, state.latestTicket)
        }
        guard let (encode, ticket) = job else { return resumeFinished() }
        // Made outside both locks: a submit while they are made queues the next drain.
        guard let data = encode() else {
            // Nothing to write for this ticket (the encode failed and logged): its waiter does not wait it out.
            state.withLock { complete(&$0, ticket: ticket) }
            return resumeFinished()
        }
        let unchanged = state.withLock { state in
            guard data == state.written else { return false }
            complete(&state, ticket: ticket)
            return true
        }
        guard !unchanged else { return resumeFinished() }
        fileLock.withLock { _ in
            // Closed while the bytes were made: the file is gone on purpose; write nothing.
            guard !state.withLock({ $0.closed }) else { return }
            do {
                try writer(data, url)
                state.withLock { state in
                    state.written = data
                    state.writes += 1
                    complete(&state, ticket: ticket)
                }
            } catch {
                // The next submit tries again; a waiter gets its deadline.
            }
        }
        resumeFinished()
    }

    private func complete(_ state: inout State, ticket: UInt64) {
        state.completed = max(state.completed, ticket)
    }

    private func resumeFinished() {
        let done = state.withLock { state in
            let completed = state.completed
            let done = state.waiters.filter { $0.ticket <= completed }
            state.waiters.removeAll { $0.ticket <= completed }
            return done
        }
        for waiter in done { waiter.continuation.resume(returning: true) }
    }

    private func expire(_ id: UInt64) {
        let waiter = state.withLock { state -> Waiter? in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return state.waiters.remove(at: index)
        }
        waiter?.continuation.resume(returning: false)
    }

    /// Writes `data` to a temporary file next to `url`, then renames it
    /// over `url`. No fsync (see the type's comment).
    public static func replaceAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(getpid()).tmp").path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let count = data.withUnsafeBytes { bytes in
            // concurrency-allow: nonisolated; runs on RunMarkerFile's background queue, never on the main actor.
            bytes.baseAddress.map { Darwin.write(descriptor, $0, bytes.count) } ?? 0
        }
        let writeError = errno
        Darwin.close(descriptor)
        guard count == data.count else {
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: writeError) ?? .EIO)
        }
        guard rename(temporary, url.path) == 0 else {
            let renameError = errno
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: renameError) ?? .EIO)
        }
    }
}
