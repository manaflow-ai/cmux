import Foundation
import GhosttyNextKit
import Synchronization

/// Serial, non-main lane for every call that must be serialized with
/// `ghostty_surface_process_output` (ghostty.h:1373-1380, :1589):
/// output, Kitty replay restore, theme updates.
///
/// `process_output` takes the renderer-state mutex synchronously, so it runs
/// off the main thread (cmux-tui-contract.md 3.2).
///
/// Bounded (state-audit.md T1/T2): ``waitForCapacity()`` suspends the
/// session's event loop while more than `highWater` bytes wait to be parsed,
/// so backpressure reaches the attachment instead of piling up here, and
/// ``drained()`` waits for the backlog without blocking the main thread.
/// ``close()`` fences the lane before `ghostty_surface_free`; queued work is
/// skipped from then on, so the fence waits for at most one chunk.
nonisolated final class TerminalOutputLane: @unchecked Sendable {
    let highWater: Int
    private let queue: DispatchQueue
    /// Touched only on `queue`.
    private var surface: ghostty_surface_t?
    private let closing = Atomic<Bool>(false)

    private struct Backlog {
        var bytes = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let backlog = Mutex(Backlog())

    init(surface: ghostty_surface_t, label: String, highWater: Int = 2 << 20) {
        self.surface = surface
        self.highWater = highWater
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    /// Bytes queued but not parsed yet.
    var pendingBytes: Int { backlog.withLock { $0.bytes } }

    func processOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        backlog.withLock { $0.bytes += data.count }
        queue.async { [self] in
            defer { parsed(data.count) }
            guard let surface, !closing.load(ordering: .relaxed) else { return }
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_process_output(surface, base, UInt(buffer.count))
            }
        }
    }

    /// Returns once the unparsed backlog is at or below `highWater` (or the
    /// lane closed). The caller then queues its next chunk.
    func waitForCapacity() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let parked = backlog.withLock { backlog -> Bool in
                guard backlog.bytes > highWater, !closing.load(ordering: .relaxed) else { return false }
                backlog.waiters.append(waiter)
                return true
            }
            if !parked { waiter.resume() }
        }
    }

    /// Runs `body` on the lane with the live surface, or not at all after
    /// ``close()``.
    func perform(_ body: @escaping @Sendable (ghostty_surface_t) -> Void) {
        queue.async { [self] in
            guard let surface, !closing.load(ordering: .relaxed) else { return }
            body(surface)
        }
    }

    /// Resumes once every chunk queued so far has been parsed. The session
    /// awaits this before a call that must observe the parsed state but is
    /// not lane-safe. The main thread never blocks on it.
    func drained() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }

    /// Skips queued work, waits for the chunk in flight, then drops the
    /// surface so nothing else touches it. Call on the main actor
    /// immediately before `ghostty_surface_free`.
    func close() {
        closing.store(true, ordering: .relaxed)
        let waiters = backlog.withLock { backlog -> [CheckedContinuation<Void, Never>] in
            defer { backlog.waiters = [] }
            return backlog.waiters
        }
        waiters.forEach { $0.resume() }
        // concurrency-allow: bounded fence before ghostty_surface_free; queued chunks are skipped once `closing` is set, so this waits for at most the one chunk being parsed.
        queue.sync { surface = nil }
    }

    private func parsed(_ count: Int) {
        let waiters = backlog.withLock { backlog -> [CheckedContinuation<Void, Never>] in
            backlog.bytes -= count
            guard backlog.bytes <= highWater, !backlog.waiters.isEmpty else { return [] }
            defer { backlog.waiters = [] }
            return backlog.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
