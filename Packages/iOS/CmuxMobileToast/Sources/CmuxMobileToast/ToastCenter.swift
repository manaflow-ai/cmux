public import Foundation
public import Observation

#if canImport(UIKit)
internal import UIKit
#endif

/// The app-wide toast presenter: one instance owns which toast is visible,
/// the FIFO queue behind it, and every dwell/coalescing/interaction policy.
///
/// Views never decide toast lifetime. They render ``presented`` inside a
/// `toastHost(_:)` overlay, forward drags through ``beginInteraction()`` /
/// ``endInteraction()``, and call ``dismiss(_:)``. All timing runs on the
/// injected clock so the policy is testable without wall-clock sleeps.
@MainActor
@Observable
public final class ToastCenter {
    /// The visible toast plus how many times a coalescing present re-alerted it.
    public struct Presented: Equatable, Sendable {
        public let toast: Toast
        /// Incremented when `present(_:)` refreshes the visible toast in place
        /// (same ``Toast/coalescingKey``); the host animates a pulse per bump.
        public let bumpCount: Int
    }

    public private(set) var presented: Presented?

    /// Beta gate: while false (the default), `present(_:)` drops every toast
    /// so the app behaves as if the system doesn't exist. Persisted, and
    /// surfaced as the "Toasts" toggle under Settings → Beta Features.
    /// Call sites with a legacy surface (the old workspace-action banner,
    /// chat error banner, copy-button morph) branch on this to fall back.
    public var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if !isEnabled {
                dismissAll()
            }
        }
    }

    public static let enabledDefaultsKey = "cmux.toasts.betaEnabled"

    @ObservationIgnored private let defaults: UserDefaults

    /// Toasts waiting behind the visible one, oldest first. Capped: a burst
    /// of notices drops the oldest queued toast rather than backing up into
    /// a stale parade.
    @ObservationIgnored private(set) var queue: [Toast] = []

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private(set) var autoDismissTask: Task<Void, Never>?
    @ObservationIgnored private(set) var advanceTask: Task<Void, Never>?
    @ObservationIgnored private var interactionHolds = 0

    /// Whether dwell should be extended for assistive tech (VoiceOver needs
    /// time to speak the announcement before the toast leaves). Injectable
    /// for tests.
    @ObservationIgnored var prefersExtendedDwell: @MainActor () -> Bool

    static let queueLimit = 3
    /// Breath between consecutive toasts so the departure reads before the
    /// next arrival.
    static let interToastGap: Duration = .milliseconds(260)

    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        defaults: UserDefaults = .standard
    ) {
        self.clock = clock
        self.defaults = defaults
        var enabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        #if DEBUG
        // The env-gated gallery harness exists to exercise toasts; a dark
        // default there would make every gallery run a silent no-op.
        if ProcessInfo.processInfo.environment["CMUX_TOAST_GALLERY"] == "1" {
            enabled = true
        }
        #endif
        self.isEnabled = enabled
        #if os(iOS)
        prefersExtendedDwell = {
            UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        }
        #else
        prefersExtendedDwell = { false }
        #endif
    }

    /// Present a toast: shows it now if nothing is visible, refreshes and
    /// re-bumps the visible toast when the ``Toast/coalescingKey`` matches,
    /// and queues (FIFO, capped) otherwise. Dropped while ``isEnabled`` is
    /// false (the beta flag is off).
    public func present(_ toast: Toast) {
        guard isEnabled else { return }
        if let current = presented, current.toast.coalescingKey == toast.coalescingKey {
            presented = Presented(
                toast: toast.adoptingIdentity(of: current.toast),
                bumpCount: current.bumpCount + 1
            )
            restartAutoDismiss()
            return
        }
        if presented != nil || advanceTask != nil {
            if let index = queue.firstIndex(where: { $0.coalescingKey == toast.coalescingKey }) {
                queue[index] = toast.adoptingIdentity(of: queue[index])
            } else {
                queue.append(toast)
                if queue.count > Self.queueLimit {
                    queue.removeFirst(queue.count - Self.queueLimit)
                }
            }
            return
        }
        show(toast)
    }

    /// Dismiss a specific toast wherever it is: the visible one animates out
    /// (and the queue advances); a queued one is silently dropped.
    public func dismiss(_ id: Toast.ID) {
        if presented?.toast.id == id {
            dismissCurrent()
        } else {
            queue.removeAll { $0.id == id }
        }
    }

    /// Dismiss the visible toast and advance to the next queued one after a
    /// short gap.
    public func dismissCurrent() {
        guard presented != nil else { return }
        cancelAutoDismiss()
        presented = nil
        interactionHolds = 0
        scheduleAdvance()
    }

    /// Drop everything, including queued toasts. For hard context switches
    /// such as sign-out.
    public func dismissAll() {
        cancelAutoDismiss()
        advanceTask?.cancel()
        advanceTask = nil
        queue.removeAll()
        presented = nil
        interactionHolds = 0
    }

    /// The user started touching the toast; auto-dismiss holds until every
    /// balanced ``endInteraction(for:)`` lands. Scoped to the presented
    /// toast's id so a straggling gesture from a departing toast can never
    /// hold (or resume) its successor's dwell.
    public func beginInteraction(for toastID: Toast.ID) {
        guard presented?.toast.id == toastID else { return }
        interactionHolds += 1
        cancelAutoDismiss()
    }

    /// Balances ``beginInteraction(for:)``. When the last hold releases, the
    /// full dwell restarts (forgiving: touching a toast means the user is
    /// reading it).
    public func endInteraction(for toastID: Toast.ID) {
        guard presented?.toast.id == toastID, interactionHolds > 0 else { return }
        interactionHolds -= 1
        if interactionHolds == 0 {
            restartAutoDismiss()
        }
    }

    private func show(_ toast: Toast) {
        // A cancelled drag on the previous toast can leak a hold; interaction
        // is per-toast, so a fresh presentation always starts unheld.
        interactionHolds = 0
        presented = Presented(toast: toast, bumpCount: 0)
        restartAutoDismiss()
    }

    private func restartAutoDismiss() {
        cancelAutoDismiss()
        guard interactionHolds == 0,
              let presented,
              case .after(let duration) = presented.toast.autoDismiss else { return }
        let dwell = prefersExtendedDwell() ? duration * 2 : duration
        let toastID = presented.toast.id
        autoDismissTask = Task { [weak self, clock] in
            try? await clock.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            self?.autoDismissFired(toastID: toastID)
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }

    private func autoDismissFired(toastID: UUID) {
        guard presented?.toast.id == toastID else { return }
        dismissCurrent()
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard !queue.isEmpty else {
            advanceTask = nil
            return
        }
        advanceTask = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.interToastGap)
            guard !Task.isCancelled else { return }
            self?.advanceFired()
        }
    }

    private func advanceFired() {
        advanceTask = nil
        guard presented == nil, !queue.isEmpty else { return }
        show(queue.removeFirst())
    }
}
