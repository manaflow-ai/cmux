import Foundation
import OSLog
import CmuxNotifications

nonisolated private let focusSurfaceBroadcasterLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "FocusSurfaceBroadcaster"
)

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
/// the re-entrant SwiftUI/AppKit layout loop reported in
/// https://github.com/manaflow-ai/cmux/issues/8843.
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
///   scheduled flush. Consecutive bounded turns are capped by
///   ``maxConsecutiveBoundedFlushes``; after that the pending payload gets one
///   delayed recovery delivery and the breaker stays open until a new external
///   focus emit arrives, so a non-converging observer cycle cannot monopolize
///   SwiftUI/AppKit layout work.
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
        /// Stable identity for one logical focus transaction and its feedback.
        let transactionId: UUID

        /// Creates a payload describing a focused surface.
        init(
            workspaceId: UUID,
            panelId: UUID,
            explicitFocusIntent: Bool,
            transactionId: UUID = UUID()
        ) {
            self.workspaceId = workspaceId
            self.panelId = panelId
            self.explicitFocusIntent = explicitFocusIntent
            self.transactionId = transactionId
        }
    }

    /// The app-wide broadcaster used by ``Workspace`` to emit focus broadcasts.
    ///
    /// Posts the real `.ghosttyDidFocusSurface` notification and logs (DEBUG builds)
    /// whenever the bounded drain trips, and logs when the cross-turn circuit
    /// breaker trips and moves the pending payload onto bounded recovery, so a
    /// future re-entrancy regression is observable instead of a silent hours-long
    /// hang.
    static let shared = FocusSurfaceBroadcaster(
        onDrainBoundExceeded: { payload in
#if DEBUG
            cmuxDebugLog(
                "focus.broadcast.drain.exceeded workspace=\(payload.workspaceId.uuidString.prefix(5)) " +
                "panel=\(payload.panelId.uuidString.prefix(5)) tx=\(payload.transactionId.uuidString.prefix(5)) " +
                "explicit=\(payload.explicitFocusIntent ? 1 : 0)"
            )
#endif
        },
        onCircuitBreakerTripped: { payload in
            let message = "focus.broadcast.circuitBreaker.tripped workspace=\(payload.workspaceId.uuidString.prefix(5)) " +
                "panel=\(payload.panelId.uuidString.prefix(5)) tx=\(payload.transactionId.uuidString.prefix(5)) " +
                "explicit=\(payload.explicitFocusIntent ? 1 : 0)"
#if DEBUG
            cmuxDebugLog(message)
#endif
            focusSurfaceBroadcasterLogger.error("\(message, privacy: .public)")
        }
    )

    private let coalescer: FocusSurfaceBroadcastCoalescer<FocusSurfacePayload>

    /// Creates a broadcaster.
    ///
    /// - Parameters:
    ///   - maxCoalescedDeliveries: Upper bound on deliveries performed by a single
    ///     flush. Caps a re-entrant focus cycle so it can never hang. Defaults to 8,
    ///     matching `Workspace.applyTabSelection`'s existing per-instance drain bound.
    ///   - maxConsecutiveBoundedFlushes: Upper bound on consecutive scheduled flushes
    ///     that are allowed to hit ``maxCoalescedDeliveries``. This is the runtime
    ///     circuit breaker for a non-converging focus observer loop.
    ///   - maxConsecutiveCircuitDeliveries: Upper bound on deliveries for the same
    ///     focus transaction, including feedback deferred to later main-queue turns.
    ///   - maxCircuitBreakerRecoveryDeliveries: Upper bound on retained same-transaction
    ///     payloads delivered after the breaker trips.
    ///   - schedule: Schedules deferred flush work on the main queue. Defaults to
    ///     `DispatchQueue.main.async`. Injected by tests to flush deterministically.
    ///   - onDrainBoundExceeded: Invoked with the still-pending payload when a flush
    ///     hits ``maxCoalescedDeliveries`` and defers the remainder to a follow-up
    ///     flush. Used for structured logging of a non-converging focus cycle.
    ///   - onCircuitBreakerTripped: Invoked with the retained pending payload when
    ///     the cross-turn circuit breaker rate-limits a non-converging cycle.
    ///   - deliver: Performs the actual broadcast. Defaults to posting
    ///     `.ghosttyDidFocusSurface`. Injected by tests to capture deliveries.
    init(
        maxCoalescedDeliveries: Int = 8,
        maxConsecutiveBoundedFlushes: Int = 4,
        maxConsecutiveCircuitDeliveries: Int? = nil,
        maxCircuitBreakerRecoveryDeliveries: Int? = nil,
        schedule: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
            }
        },
        onDrainBoundExceeded: @escaping @MainActor @Sendable (FocusSurfacePayload) -> Void = { _ in },
        onCircuitBreakerTripped: @escaping @MainActor @Sendable (FocusSurfacePayload) -> Void = { _ in },
        deliver: @escaping @MainActor @Sendable (FocusSurfacePayload) -> Void = { payload in
            NotificationCenter.default.post(
                name: .ghosttyDidFocusSurface,
                object: nil,
                userInfo: [
                    GhosttyNotificationKey.tabId: payload.workspaceId,
                    GhosttyNotificationKey.surfaceId: payload.panelId,
                    GhosttyNotificationKey.explicitFocusIntent: payload.explicitFocusIntent,
                    GhosttyNotificationKey.focusTransactionId: payload.transactionId,
                ]
            )
        }
    ) {
        self.coalescer = FocusSurfaceBroadcastCoalescer(
            maxCoalescedDeliveries: maxCoalescedDeliveries,
            maxConsecutiveBoundedFlushes: maxConsecutiveBoundedFlushes,
            maxConsecutiveCircuitDeliveries: maxConsecutiveCircuitDeliveries,
            maxCircuitBreakerRecoveryDeliveries: maxCircuitBreakerRecoveryDeliveries,
            belongsToSameCircuit: { $0.transactionId == $1.transactionId },
            schedule: schedule,
            onDrainBoundExceeded: onDrainBoundExceeded,
            onCircuitBreakerTripped: onCircuitBreakerTripped,
            deliver: deliver
        )
    }

    /// Records a focus broadcast for asynchronous, coalesced delivery.
    ///
    /// Never delivers synchronously: this is what makes emitting safe while
    /// `@Published` selection state is mid-mutation. If a delivery is already in
    /// progress (an observer re-entered during a flush), the payload is recorded for
    /// the active drain loop instead of scheduling another flush.
    func emit(_ payload: FocusSurfacePayload) {
        coalescer.emit(payload)
    }

    /// Delivers the pending broadcast(s) on the main queue.
    ///
    /// Drains coalesced payloads in a bounded loop so a re-entrant observer cannot
    /// spin forever. Exposed (non-private) so tests can run the scheduled flush
    /// deterministically.
    func flush() {
        coalescer.flush()
    }
}
