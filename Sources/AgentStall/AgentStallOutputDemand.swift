import CmuxFoundation
import Foundation
import os

/// Immutable capture identity consulted from a terminal's serialized PTY tee.
struct AgentStallOutputDemandDescriptor: Equatable, Sendable {
    let workspaceID: UUID
    let epoch: UInt64
}

/// The bounded PTY evidence captured for one managed turn boundary.
struct AgentStallOutputCapture: Sendable {
    let descriptor: AgentStallOutputDemandDescriptor
    let tail: Data
}

/// Per-surface bounded output capture read directly by that surface's
/// serialized PTY callback.
///
/// SAFETY: libghostty serializes callbacks for one surface. The lock only
/// coordinates that callback with the main-actor begin/finish operations; no
/// terminal ever contends with an unrelated surface. Mutable supervisor state
/// remains main-actor isolated in ``AgentStallSupervisor``.
final class AgentStallOutputCaptureBuffer: @unchecked Sendable {
    /// Borrowed callback bytes transported through `OSAllocatedUnfairLock`'s
    /// synchronous `@Sendable` closure.
    ///
    /// SAFETY: `append(_:)` never stores this pointer, and `withLock` returns
    /// before the libghostty callback's `UnsafeBufferPointer` lifetime ends.
    private struct SynchronousBytes: @unchecked Sendable {
        let baseAddress: UnsafePointer<UInt8>
        let count: Int
    }

    private final class CaptureState: @unchecked Sendable {
        let descriptor: AgentStallOutputDemandDescriptor
        var tail = Data()

        init(descriptor: AgentStallOutputDemandDescriptor) {
            self.descriptor = descriptor
        }
    }

    private static let maximumTailBytes = 64 * 1024
    // Compact in batches instead of shifting a full 64 KiB buffer for every
    // PTY chunk once the tail reaches capacity.
    private static let maximumBufferedBytes = maximumTailBytes * 2
    private let hasCaptureDemand = AtomicBooleanGate(false)
    // A synchronous libghostty PTY callback cannot await an actor while it
    // borrows its byte buffer. This is the narrow callback-seam carve-out:
    // the lock protects only the bounded capture handoff, never supervisor
    // domain state, and is held for one non-blocking append/swap operation.
    private let lock = OSAllocatedUnfairLock<CaptureState?>(initialState: nil)

    func beginCapture(_ descriptor: AgentStallOutputDemandDescriptor) {
        lock.withLock { capture in
            capture = CaptureState(descriptor: descriptor)
            // Publish the demand while the state lock is held. A callback that
            // observes `true` can therefore always find the descriptor; bytes
            // observed before this publication belong to the prior boundary.
            hasCaptureDemand.storeRelease(true)
        }
    }

    /// Appends bytes from the serialized PTY callback without copying the
    /// accumulated tail for every chunk. The one bounded snapshot is copied
    /// only when the hook proves that the provider returned to its prompt.
    func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard hasCaptureDemand.loadAcquire() else { return }
        guard let baseAddress = bytes.baseAddress, bytes.count > 0 else { return }
        let chunk = SynchronousBytes(baseAddress: baseAddress, count: bytes.count)
        lock.withLock { state in
            guard let capture = state else { return }
            if chunk.count >= Self.maximumTailBytes {
                capture.tail = Data(
                    bytes: chunk.baseAddress.advanced(by: chunk.count - Self.maximumTailBytes),
                    count: Self.maximumTailBytes
                )
            } else {
                capture.tail.append(chunk.baseAddress, count: chunk.count)
                if capture.tail.count > Self.maximumBufferedBytes {
                    capture.tail = Data(capture.tail.suffix(Self.maximumTailBytes))
                }
            }
        }
    }

    /// Atomically removes and returns the tail for a proven prompt boundary.
    func finishCapture() -> AgentStallOutputCapture? {
        let result = lock.withLock { state -> AgentStallOutputCapture? in
            guard let capture = state else {
                hasCaptureDemand.storeRelease(false)
                return nil
            }
            state = nil
            hasCaptureDemand.storeRelease(false)
            return AgentStallOutputCapture(
                descriptor: capture.descriptor,
                tail: capture.tail.count > Self.maximumTailBytes
                    ? Data(capture.tail.suffix(Self.maximumTailBytes))
                    : capture.tail
            )
        }
        return result
    }

    func clearCapture() {
        lock.withLock {
            $0 = nil
            hasCaptureDemand.storeRelease(false)
        }
    }
}

/// Routes rare supervisor lifecycle operations to a surface-local capture
/// buffer. PTY callbacks never consult this process-wide registry.
final class AgentStallOutputDemand: @unchecked Sendable {
    // SAFETY: runtime installation/teardown and supervisor calls are currently
    // main-actor owned. The lock makes the registry independently safe at the
    // C callback lifetime seam and prevents a stale lease from unregistering a
    // replacement surface that reused the same UUID.
    // This is a short callback-registry handoff, not a lock around mutable
    // supervisor state; the callback never waits on an actor or app model.
    private let lock = OSAllocatedUnfairLock(
        initialState: [UUID: AgentStallOutputCaptureBuffer]()
    )

    func register(
        _ buffer: AgentStallOutputCaptureBuffer,
        for surfaceID: UUID
    ) {
        let replaced = lock.withLock { buffers in
            buffers.updateValue(buffer, forKey: surfaceID)
        }
        if let replaced, replaced !== buffer {
            replaced.clearCapture()
        }
    }

    func unregister(
        _ buffer: AgentStallOutputCaptureBuffer,
        for surfaceID: UUID
    ) {
        let removed = lock.withLock { buffers -> AgentStallOutputCaptureBuffer? in
            guard buffers[surfaceID] === buffer else { return nil }
            return buffers.removeValue(forKey: surfaceID)
        }
        removed?.clearCapture()
    }

    @discardableResult
    func beginCapture(
        _ descriptor: AgentStallOutputDemandDescriptor,
        for surfaceID: UUID
    ) -> Bool {
        guard let buffer = buffer(for: surfaceID) else { return false }
        buffer.beginCapture(descriptor)
        return true
    }

    func finishCapture(for surfaceID: UUID) -> AgentStallOutputCapture? {
        buffer(for: surfaceID)?.finishCapture()
    }

    func clearCapture(for surfaceID: UUID) {
        buffer(for: surfaceID)?.clearCapture()
    }

    /// Clears evidence without detaching live tee registrations. The bridge
    /// owns those registrations until each native surface finishes teardown.
    func clearAllCaptures() {
        let buffers = lock.withLock { Array($0.values) }
        for buffer in buffers { buffer.clearCapture() }
    }

    private func buffer(for surfaceID: UUID) -> AgentStallOutputCaptureBuffer? {
        lock.withLock { $0[surfaceID] }
    }
}
