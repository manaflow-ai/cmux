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
/// cancels queued work, while teardown drains the one operation that may already
/// be inside Ghostty before freeing the native surface. The unchecked
/// sendability is safe because the queue and lifecycle gate are the only
/// mutable state; the borrowed surface pointer is used only by queued work and
/// is drained before its owner frees it.
final class TerminalSurfaceRemoteOutputLane: @unchecked Sendable {
    private let queue: DispatchQueue
    // Short lifecycle gate: only a Boolean read/write is protected, and the
    // lock is never held across a native call or a suspension point.
    private let isOpen = OSAllocatedUnfairLock(initialState: true)

    init(surfaceID: UUID, generation: UInt64) {
        queue = DispatchQueue(
            label: "com.cmux.terminal-surface.remote-output.\(surfaceID.uuidString).\(generation)",
            qos: .userInitiated
        )
    }

    /// Enqueues one ordered output batch and its refresh signal.
    func enqueue(_ data: Data, to surface: ghostty_surface_t) {
        guard !data.isEmpty, isOpen.withLock({ $0 }) else { return }
        // Raw pointers are represented as bits across the Sendable queue
        // boundary; the lane fence owns the native lifetime until this work
        // has completed.
        let surfaceBits = UInt(bitPattern: surface)
        queue.async { [isOpen, surfaceBits] in
            guard isOpen.withLock({ $0 }) else { return }
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

    /// Enqueues manual text input behind earlier remote output.
    @discardableResult
    func enqueueTextInput(_ data: Data, to surface: ghostty_surface_t) -> Bool {
        guard !data.isEmpty, isOpen.withLock({ $0 }) else { return false }
        let surfaceBits = UInt(bitPattern: surface)
        queue.async { [isOpen, surfaceBits] in
            guard isOpen.withLock({ $0 }) else { return }
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

    /// Prevents queued work for this runtime generation from touching its pointer.
    func close() {
        isOpen.withLock { $0 = false }
    }

    /// Closes the lane and invokes `completion` after its FIFO fence runs.
    ///
    /// The caller never waits for the fence. If Ghostty is wedged inside an
    /// already-running operation, the lane worker remains the only blocked
    /// thread; the teardown coordinator can keep its native-free worker slots
    /// available until the fence eventually completes.
    func scheduleDrain(_ completion: @escaping @Sendable () -> Void) {
        close()
        queue.async(execute: completion)
    }

#if DEBUG
    /// Synchronously fences test-only direct-free helpers after queued work is done.
    /// This is unavailable in release builds; production teardown uses
    /// ``scheduleDrain(_:)`` so no app worker waits on the lane.
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
