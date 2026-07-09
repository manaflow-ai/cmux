public import Foundation

/// Schedules a coalesced panel-title flush on the window's main run loop.
///
/// ``SurfaceMetadataCoordinator`` owns the coalescing bookkeeping (the pending
/// per-surface title batch) but defers the *timing* of the flush to a
/// scheduler: rapid title bursts are collapsed into one flush after a short
/// delay so only the latest title per panel is applied. The production
/// conformer is ``NotificationBurstCoalescer``; tests inject a synchronous
/// fake so the flush can be driven deterministically.
@MainActor
public protocol TitleFlushScheduling: AnyObject {
    /// Records `action` as the pending flush and arranges for it to run once
    /// after the scheduler's delay. A later `signal` in the same burst replaces
    /// the pending action and does not schedule a second flush.
    func signal(_ action: @escaping () -> Void)
}

/// A title-flush scheduler whose delay is supplied per signal by the app layer.
@MainActor
public protocol TitleFlushDelayScheduling: TitleFlushScheduling {
    /// Records `action` as the pending flush using the caller-resolved delay.
    func signal(delay: TimeInterval, _ action: @escaping () -> Void)
}
