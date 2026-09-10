internal import Dispatch
internal import Foundation
internal import GhosttyKit
internal import os

/// Serializes manually injected terminal output away from the main actor.
///
/// Ghostty's output parser takes the renderer-state mutex synchronously. Remote
/// tmux notifications arrive on the main actor, so invoking that parser inline
/// can park the UI indefinitely while a renderer or a stale native owner holds
/// the mutex. Each runtime generation gets its own lane; closing a generation
/// rejects new work while preserving FIFO order for already-admitted work, and
/// teardown drains that work before freeing the native surface. The unchecked
/// sendability is safe because the queue and lifecycle gate are the only
/// mutable state; the borrowed surface pointer is used only by queued work and
/// is drained before its owner frees it.
final class TerminalSurfaceRemoteOutputLane: @unchecked Sendable {
    private let queue: DispatchQueue
    // The synchronous gate is required because enqueueTextInput and close can
    // race from the main actor and teardown/lane threads; an actor hop could
    // accept work after retirement. Only one Boolean read/write is protected,
    // and the lock is never held across a native call or suspension point.
    private let isOpen = OSAllocatedUnfairLock(initialState: true)

    init(surfaceID: UUID, generation: UInt64) {
        queue = DispatchQueue(
            label: "com.cmux.terminal-surface.remote-output.\(surfaceID.uuidString).\(generation)",
            qos: .userInitiated
        )
    }

    /// Enqueues one ordered output batch and its refresh signal.
    func enqueue(_ data: Data, to surface: ghostty_surface_t) {
        guard !data.isEmpty else { return }
        // Raw pointers are represented as bits across the Sendable queue
        // boundary; the lane fence owns the native lifetime until this work
        // has completed.
        let surfaceBits = UInt(bitPattern: surface)
        isOpen.withLock { isOpen in
            guard isOpen else { return }
            // Admission and queue submission share the gate with `close()`,
            // so every accepted operation is ahead of the drain fence.
            queue.async { [surfaceBits] in
                guard let surface = UnsafeMutableRawPointer(bitPattern: surfaceBits) else {
                    return
                }
                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                        return
                    }
                    ghostty_surface_process_output(surface, baseAddress, UInt(rawBuffer.count))
                }
                ghostty_surface_refresh(surface)
            }
        }
    }

    /// Enqueues manual text input behind earlier remote output.
    @discardableResult
    func enqueueTextInput(_ data: Data, to surface: ghostty_surface_t) -> Bool {
        guard !data.isEmpty else { return false }
        let surfaceBits = UInt(bitPattern: surface)
        return isOpen.withLock { isOpen in
            guard isOpen else { return false }
            // Keep queue submission inside the same admission critical
            // section as `close()`; the native call itself remains outside it.
            queue.async { [surfaceBits] in
                guard let surface = UnsafeMutableRawPointer(bitPattern: surfaceBits) else {
                    return
                }
                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                        return
                    }
                    ghostty_surface_text_input(surface, baseAddress, UInt(rawBuffer.count))
                }
            }
            return true
        }
    }

    /// Stops admission of new work for this runtime generation.
    ///
    /// Operations accepted before this call remain in FIFO order and are
    /// drained before native teardown; later submissions are rejected.
    func close() {
        isOpen.withLock { $0 = false }
    }

    /// Closes the lane and asynchronously waits for its FIFO fence.
    ///
    /// Awaiting this method suspends the caller instead of blocking a thread.
    /// If Ghostty is wedged inside an already-running operation, only the lane
    /// worker remains blocked until that native call returns.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Keep close and fence submission in one critical section. Every
            // operation admitted before the state flip is already queued ahead
            // of this fence, and no operation can be admitted in between.
            isOpen.withLock { isOpen in
                isOpen = false
                queue.async {
                    continuation.resume()
                }
            }
        }
    }

#if DEBUG
    /// Synchronously fences test-only direct-free helpers after queued work is done.
    /// This is unavailable in release builds; production teardown uses
    /// ``drain()`` so no app worker waits on the lane.
    func drainSynchronouslyForTesting() {
        close()
        queue.sync {}
    }
#endif
}

extension TerminalSurface {
    /// Retires the current output lane and opens one for the next runtime generation.
    @MainActor
    func retireRemoteOutputLane() -> TerminalSurfaceRemoteOutputLane {
        let retired = remoteOutputLane
        retired.close()
        remoteOutputLaneGeneration &+= 1
        remoteOutputLane = TerminalSurfaceRemoteOutputLane(
            surfaceID: id,
            generation: remoteOutputLaneGeneration
        )
        return retired
    }
}
