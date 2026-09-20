import Foundation

/// Mutable bookkeeping for one runtime's host-layer presentation probe.
/// Access is confined to the owning surface's main-actor lifecycle methods.
final class TerminalRendererPresentationState {
    @MainActor var queuedFrameWaiters: [UUID: CheckedContinuation<UInt64?, Never>] = [:]
    @MainActor var frameWaiters: [UUID: CheckedContinuation<UInt64?, Never>] = [:]

    @MainActor
    func completeFrameWaiters(_ token: UInt64?) {
        completeActiveFrameWaiters(token)
        let queued = queuedFrameWaiters.values
        queuedFrameWaiters.removeAll()
        for waiter in queued { waiter.resume(returning: token) }
    }

    @MainActor
    func completeActiveFrameWaiters(_ token: UInt64?) {
        let active = frameWaiters.values
        frameWaiters.removeAll()
        for waiter in active { waiter.resume(returning: token) }
    }

    @MainActor
    func cancelFrameWaiter(_ id: UUID) {
        frameWaiters.removeValue(forKey: id)?.resume(returning: nil)
        queuedFrameWaiters.removeValue(forKey: id)?.resume(returning: nil)
    }

    var token: UInt64 = 0
    var inFlightToken: UInt64?
    var recoveryAttempted = false
    /// Whether the current renderer lifetime has delivered at least one frame.
    /// This remains true when a shell exits so diagnostics can coexist with
    /// the last usable frame, including after renderer reclamation.
    var didPresentFrame = false
}
