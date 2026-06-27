import CmuxTerminal
import Foundation

/// Coalesces and defers `.ghosttyDidFocusSurface` focus broadcasts so that emitting
/// one mid-mutation can never synchronously re-enter the focus/selection path.
///
/// ## Why this exists
///
/// `Workspace.applyTabSelectionNow` mutates a large amount of `@Published` selection
/// state and, historically, finished by posting `.ghosttyDidFocusSurface`
/// *synchronously*. The Combine `.onReceive` subscriber in `ContentView` delivers
/// that notification synchronously on the posting thread and reacts by calling back
/// into `TabManager.focusTab` → `Workspace.focusPanel` → `applyTabSelectionNow`,
/// which posts the notification again. Because the only re-entrancy guard
/// (`Workspace.isApplyingTabSelection`) is *per-instance*, a cycle that bounces
/// through SwiftUI body re-evaluation and across different `Workspace` instances
/// (command-palette focus restore + cross-workspace handoff) was unbounded. That is
/// the 426s main-thread hang in https://github.com/manaflow-ai/cmux/issues/5100.
///
/// ## Contract
///
/// - ``emit(_:)`` never delivers synchronously. It records the latest payload and
///   schedules a single flush on the main queue, so all `@Published` mutations made
///   by the caller settle before any observer runs.
/// - Multiple emits before a flush coalesce to the most recent payload.
/// - If an observer synchronously emits again during delivery, that emit updates the
///   pending payload instead of recursing; the active flush drains it in a bounded
///   loop (at most ``maxCoalescedDeliveries`` deliveries per turn). If the cycle has
///   not settled within that bound, the still-pending payload is carried to a fresh
///   scheduled flush rather than delivered synchronously or dropped — so work stays
///   bounded per runloop turn (the app keeps responding) while the final selection is
///   never lost. A notification-driven focus cycle can therefore no longer hang.
///
/// The type is fully testable without AppKit: inject ``deliver`` to capture
/// broadcasts, and inject ``schedule`` to drive flushes deterministically.
@MainActor
final class FocusSurfaceBroadcaster {
    /// The focused-surface identity carried by a `.ghosttyDidFocusSurface` broadcast.
    struct FocusSurfacePayload: Equatable, Sendable {
        /// The workspace (tab) whose surface gained focus.
        let workspaceId: UUID
        /// The focused panel/surface within ``workspaceId``.
        let panelId: UUID
        /// Whether the focus change reflects explicit user intent.
        let explicitFocusIntent: Bool

        /// Creates a payload describing a focused surface.
        init(workspaceId: UUID, panelId: UUID, explicitFocusIntent: Bool) {
            self.workspaceId = workspaceId
            self.panelId = panelId
            self.explicitFocusIntent = explicitFocusIntent
        }
    }

    /// The app-wide broadcaster used by ``Workspace`` to emit focus broadcasts.
    ///
    /// Posts the real `.ghosttyDidFocusSurface` notification and logs (DEBUG builds)
    /// whenever the bounded drain trips, so a future re-entrancy regression is
    /// observable instead of a silent hang.
    static let shared = FocusSurfaceBroadcaster(
        onDrainBoundExceeded: { payload in
#if DEBUG
            cmuxDebugLog(
                "focus.broadcast.drain.exceeded workspace=\(payload.workspaceId.uuidString.prefix(5)) " +
                "panel=\(payload.panelId.uuidString.prefix(5)) explicit=\(payload.explicitFocusIntent ? 1 : 0)"
            )
#endif
        }
    )

    private let deliver: @MainActor (FocusSurfacePayload) -> Void
    private let schedule: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
    private let maxCoalescedDeliveries: Int
    private let onDrainBoundExceeded: @MainActor (FocusSurfacePayload) -> Void

    private var pending: FocusSurfacePayload?
    private var flushScheduled = false
    private var isDelivering = false

    /// Creates a broadcaster.
    ///
    /// - Parameters:
    ///   - maxCoalescedDeliveries: Upper bound on deliveries performed by a single
    ///     flush. Caps a re-entrant focus cycle so it can never hang. Defaults to 8,
    ///     matching `Workspace.applyTabSelection`'s existing per-instance drain bound.
    ///   - schedule: Schedules deferred flush work on the main queue. Defaults to
    ///     `DispatchQueue.main.async`. Injected by tests to flush deterministically.
    ///   - onDrainBoundExceeded: Invoked with the still-pending payload when a flush
    ///     hits ``maxCoalescedDeliveries`` and defers the remainder to a follow-up
    ///     flush. Used for structured logging of a non-converging focus cycle.
    ///   - deliver: Performs the actual broadcast. Defaults to posting
    ///     `.ghosttyDidFocusSurface`. Injected by tests to capture deliveries.
    init(
        maxCoalescedDeliveries: Int = 8,
        schedule: @escaping @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
            }
        },
        onDrainBoundExceeded: @escaping @MainActor (FocusSurfacePayload) -> Void = { _ in },
        deliver: @escaping @MainActor (FocusSurfacePayload) -> Void = { payload in
            NotificationCenter.default.post(
                name: .ghosttyDidFocusSurface,
                object: nil,
                userInfo: [
                    GhosttyNotificationKey.tabId: payload.workspaceId,
                    GhosttyNotificationKey.surfaceId: payload.panelId,
                    GhosttyNotificationKey.explicitFocusIntent: payload.explicitFocusIntent,
                ]
            )
        }
    ) {
        self.maxCoalescedDeliveries = max(1, maxCoalescedDeliveries)
        self.schedule = schedule
        self.onDrainBoundExceeded = onDrainBoundExceeded
        self.deliver = deliver
    }

    /// Records a focus broadcast for asynchronous, coalesced delivery.
    ///
    /// Never delivers synchronously: this is what makes emitting safe while
    /// `@Published` selection state is mid-mutation. If a delivery is already in
    /// progress (an observer re-entered during a flush), the payload is recorded for
    /// the active drain loop instead of scheduling another flush.
    func emit(_ payload: FocusSurfacePayload) {
        pending = payload
        // A re-entrant emit during delivery hands the payload to the running drain
        // loop; scheduling another flush here would re-introduce the storm.
        if isDelivering { return }
        if flushScheduled { return }
        flushScheduled = true
        schedule { @Sendable [weak self] in
            self?.flush()
        }
    }

    /// Delivers the pending broadcast(s) on the main queue.
    ///
    /// Drains coalesced payloads in a bounded loop so a re-entrant observer cannot
    /// spin forever. Exposed (non-private) so tests can run the scheduled flush
    /// deterministically.
    func flush() {
        flushScheduled = false
        // Defensive: never run nested deliveries even if a flush is somehow scheduled
        // while one is already draining.
        guard !isDelivering else { return }
        isDelivering = true

        var iterations = 0
        while let next = pending {
            pending = nil
            iterations += 1
            if iterations > maxCoalescedDeliveries {
                // Re-entrancy did not converge within this turn. Don't hang
                // (delivering synchronously forever) and don't drop the focus
                // update: keep the latest payload and let the post-loop reschedule
                // continue it on a fresh runloop turn. Work stays bounded *per turn*
                // (so the app keeps responding) while still settling on the final
                // selection.
                pending = next
                onDrainBoundExceeded(next)
                break
            }
            deliver(next)
        }

        isDelivering = false
        // A delivery (or `onDrainBoundExceeded`) may have left a payload pending —
        // either because the per-turn bound tripped, or because a re-entrant emit
        // raced the `isDelivering` window and returned without scheduling. Schedule
        // one more flush so the final focus selection is never stranded.
        if pending != nil, !flushScheduled {
            flushScheduled = true
            schedule { @Sendable [weak self] in
                self?.flush()
            }
        }
    }
}
