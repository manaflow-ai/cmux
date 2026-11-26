import Foundation

/// Bounds how often a paired phone's viewport reports may resize the Mac PTY.
///
/// Every mobile request that carries viewport dimensions (dedicated reports,
/// and piggybacks on input/paste/scroll/replay) funnels into one per-surface
/// governor before it may mutate the Ghostty surface. Ungoverned, each landed
/// report that differs from the current pixel box resizes the PTY, which
/// SIGWINCHes the foreground TUI into a full repaint and forces a render-grid
/// replay to the phone. Over a relay, those replays keep the downlink busy, so
/// the phone's next viewport echo is late, its report re-arms, and the cycle
/// sustains itself (a field session logged 215 full replays in 5.2 minutes on
/// one surface; https://github.com/manaflow-ai/cmux/issues/13474). The two
/// dominant flap shapes are a remount (`clear` to the native size followed
/// within a second by a re-apply of the same grid) and alternating pre/post
/// keyboard-inset geometry.
///
/// Rules:
/// - The first cap after an uncapped state applies immediately: a cold attach
///   needs the phone's grid before its replay is captured.
/// - A request equal to the applied target is dropped, and it cancels any
///   staged change (this is what collapses clear+re-apply to zero resizes).
/// - Any other change is staged and applies only when the stability window
///   elapses (`flush()`), newest staged target winning. The window is anchored
///   at the first staged change and is not extended by replacements, so a
///   continuous flap still converges to at most one resize per window.
/// - An `immediate` request (a phone explicitly left: surface closed, back
///   navigation, viewport clear, disconnect) applies at once and cancels any
///   staged change. Only an implicit departure, the TTL of an input-carried
///   report, waits for the window. The phone sends a clear only when its
///   presentation lease ends, not on UIKit remount churn, so an explicit
///   leave is not the remount flap the window absorbs.
///
/// Pure state machine: the owner schedules the flush timer when a decision
/// asks for one, and calls `flush()` when it fires.
public struct MobileViewportApplyGovernor {
    /// What the mobile report negotiation wants the surface to be.
    public enum Target: Equatable {
        /// Cap the surface grid to the paired phones' min viewport.
        case cap(columns: Int, rows: Int)
        /// Remove the mobile cap and restore the Mac pane's uncapped size.
        case uncapped
    }

    /// What the owner must do with the incoming request.
    public enum Decision: Equatable {
        /// Mutate the surface now; the target is recorded as applied.
        case apply(Target)
        /// Hold the target. When `scheduleFlush` is true the owner starts the
        /// stability-window timer; false means one is already pending.
        case stage(Target, scheduleFlush: Bool)
        /// Nothing to do: the target is already applied (any staged change is
        /// cancelled), or it is already the staged target.
        case drop
    }

    public private(set) var applied: Target?
    public private(set) var staged: Target?
    public private(set) var flushScheduled = false

    public init() {}

    /// Decides what to do with a requested target.
    /// - Parameters:
    ///   - target: The target the mobile reports now resolve to.
    ///   - immediate: `true` for an explicit leave, which must not wait for
    ///     the stability window.
    /// - Returns: The decision the owner carries out.
    public mutating func request(_ target: Target, immediate: Bool = false) -> Decision {
        if target == applied {
            // The flap cancelled out (the remount clear+re-apply shape lands
            // here). Any staged change is now moot; a pending timer fires as
            // a no-op.
            staged = nil
            return .drop
        }
        if case .cap = target, applied == nil || applied == .uncapped {
            // Cold attach: the replay fence needs the phone's grid applied
            // before the replay is captured, so the first cap never waits.
            staged = nil
            applied = target
            return .apply(target)
        }
        if target == .uncapped, applied == nil {
            // Nothing was ever capped; there is nothing to restore.
            staged = nil
            return .drop
        }
        if immediate {
            // An explicit leave: restore now. A pending timer fires as a
            // no-op because nothing stays staged.
            staged = nil
            applied = target
            return .apply(target)
        }
        if target == staged {
            return .drop
        }
        // Re-arm the timer when none is pending, and also when the staged
        // target changes kind: an uncap must always get the uncap window from
        // its own arrival (a short cap-change window must not fast-track a
        // clear whose remount re-apply is still in flight).
        let kindChanged: Bool
        switch (staged, target) {
        case (.cap, .uncapped), (.uncapped, .cap):
            kindChanged = true
        default:
            kindChanged = false
        }
        let scheduleFlush = !flushScheduled || kindChanged
        staged = target
        flushScheduled = true
        return .stage(target, scheduleFlush: scheduleFlush)
    }

    /// Called when the stability-window timer fires. Returns the target the
    /// owner must apply now, or nil when the flap cancelled out.
    public mutating func flush() -> Target? {
        flushScheduled = false
        defer { staged = nil }
        guard let staged, staged != applied else { return nil }
        applied = staged
        return staged
    }
}
