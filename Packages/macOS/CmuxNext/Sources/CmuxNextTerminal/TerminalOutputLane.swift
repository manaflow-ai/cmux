import Foundation
import GhosttyNextKit
import Synchronization
import os

/// Serial, non-main lane for every call that must be serialized with
/// `ghostty_surface_process_output` (ghostty.h:1373-1380, :1589):
/// output, grid locks and GHOSTSNP snapshot restores.
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
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "terminal")
    private let queue: DispatchQueue
    /// Touched only on `queue`.
    private var surface: ghostty_surface_t?
    private let closing = Atomic<Bool>(false)
    /// The last READY restore succeeded. Written on `queue`; history after a
    /// failed READY is skipped until the next READY.
    private let readyRestored = Atomic<Bool>(false)
    /// Whether the last READY restored (read after ``drained()``).
    var lastReadyRestored: Bool { readyRestored.load(ordering: .acquiring) }
    /// Result of the last local-history restore (a
    /// `ghostty_surface_local_history_result_e`; read after ``drained()``).
    private let localHistoryResult = Atomic<Int32>(Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.rawValue))
    var lastLocalHistoryResult: Int32 { localHistoryResult.load(ordering: .acquiring) }

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

    /// Restores GHOSTSNP bytes (`ghostty_surface_restore_snapshot`) in
    /// stream order. Counted as backlog like output, so history pages push
    /// back on the IO the same way. A failed READY leaves the terminal as it
    /// was (logged); a failed history chunk keeps the pages applied so far.
    func restoreSnapshot(_ data: Data, phase: ghostty_surface_snapshot_phase_e) {
        guard !data.isEmpty else { return }
        backlog.withLock { $0.bytes += data.count }
        queue.async { [self] in
            defer { parsed(data.count) }
            guard let surface, !closing.load(ordering: .relaxed) else { return }
            let ready = phase == GHOSTTY_SURFACE_SNAPSHOT_READY
            guard ready || readyRestored.load(ordering: .relaxed) else { return }
            let restored = data.withUnsafeBytes { buffer -> Bool in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                return ghostty_surface_restore_snapshot(surface, base, buffer.count, phase)
            }
            if ready { readyRestored.store(restored, ordering: .releasing) }
            if !restored {
                Self.logger.error("snapshot restore failed (phase \(phase.rawValue), \(data.count) bytes)")
            }
        }
    }

    /// Restores a READY cut at the owner's resize while keeping this
    /// terminal's history, reflowed by Ghostty to the new grid, when it
    /// matches the owner's check (`ghostty_surface_restore_snapshot_local_history`).
    /// A match restores with history; a mismatch restores the READY without
    /// history (the caller then asks for READY + history); an error changes
    /// nothing. History of a READY before it is abandoned either way.
    func restoreLocalHistory(_ data: Data, expectedRows: UInt64, digest: Data) {
        backlog.withLock { $0.bytes += data.count }
        queue.async { [self] in
            defer { parsed(data.count) }
            var result = Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.rawValue)
            defer { localHistoryResult.store(result, ordering: .releasing) }
            guard let surface, !closing.load(ordering: .relaxed) else { return }
            result = data.withUnsafeBytes { bytes -> Int32 in
                digest.withUnsafeBytes { check -> Int32 in
                    guard let base = bytes.bindMemory(to: UInt8.self).baseAddress,
                          let expected = check.bindMemory(to: UInt8.self).baseAddress else {
                        return Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_ERROR.rawValue)
                    }
                    return Int32(ghostty_surface_restore_snapshot_local_history(
                        surface, base, bytes.count, expectedRows, expected, check.count))
                }
            }
            // A local READY replaces the old one: no history chunk may follow it.
            readyRestored.store(false, ordering: .releasing)
            if result != Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_RESTORED.rawValue) {
                Self.logger.error("local-history restore result \(result) (\(data.count) bytes)")
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
