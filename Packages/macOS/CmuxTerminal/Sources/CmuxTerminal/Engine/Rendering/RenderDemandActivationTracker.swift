internal import CmuxTerminalCore
internal import Foundation

/// A synchronous, thread-safe on/off toggle over one `RenderDemandCounter`
/// retention, for demand sources whose caller cannot guarantee main-actor
/// isolation.
///
/// `RenderDemandCounter` itself is already lock-protected and `Sendable`,
/// but a caller still needs somewhere to hold the single outstanding
/// `RenderDemandRetention` between an "activate" and the matching
/// "deactivate" call so the toggle stays idempotent both ways. Review
/// round2 B1: the external-hover diagnostics render trigger used to store
/// that retention in a plain `GhosttyNSView` var and defer the actual
/// mutation to `DispatchQueue.main.async`, on the theory that the var
/// needed main-actor confinement — but the caller
/// (`ExternalHoverOwnerCoordinator.callSetterAndRecordPending`, invoked
/// from `ExternalHoverWorkService`'s actor, not necessarily the main
/// actor) needs the counter to already be `isActive` by the time the
/// activation call RETURNS, not on some later main-queue turn: Ghostty's
/// synchronous in-setter `queueRender()` can otherwise race ahead of the
/// async hop and the renderer thread reads `isActive == false` for the one
/// frame the demand exists to hold open. This type makes that toggle
/// synchronous by guarding the retention slot with its own lock instead of
/// main-actor isolation — callable from any thread/actor, exactly like
/// `RenderDemandCounter.retain()`/`release()` already are.
public final class RenderDemandActivationTracker: Sendable {
    /// The underlying counter. Renderer-thread readers (e.g.
    /// `GhosttyMetalLayer.nextDrawable()`) read this directly via
    /// `isActive`, same as every other `RenderDemandCounter` consumer.
    public let counter = RenderDemandCounter()

    private let lock = NSLock()
    // SAFETY: guarded by `lock`; written from `setActive` callers on
    // whichever thread/actor calls it, read back by the next `setActive`
    // call on any thread/actor.
    nonisolated(unsafe) private var release: (any RenderDemandRetention)?

    public init() {}

    /// Idempotent both ways: a second `true` while already retained, or a
    /// `false` while already released, is a no-op. Synchronous — by the
    /// time this returns, `counter.isActive` already reflects the new
    /// state for every reader on every thread.
    public func setActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if active {
            if release == nil {
                release = counter.retain()
            }
            return
        }
        release?.release()
        release = nil
    }
}
