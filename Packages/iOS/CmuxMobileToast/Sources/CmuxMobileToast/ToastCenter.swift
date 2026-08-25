public import Foundation
public import Observation
public import CMUXMobileCore

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

    /// Product policy keeps the toast surface disabled in shipped builds.
    /// The presenter remains implemented so it can be restored without
    /// rewriting the call sites that already use it.
    public internal(set) var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            diagnosticLog?.recordAppEvent(.toastFeatureChanged, count: isEnabled ? 1 : 0)
            if !isEnabled {
                dismissAll(reason: .featureDisabled)
            }
        }
    }

    @ObservationIgnored private let diagnosticLog: DiagnosticLog?

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

    /// The toast UI is shelved from the product. Keep this policy separate
    /// from the presenter so reintroducing it later is a one-line decision.
    private static let shippedEnabled = false

    /// Creates a presenter using the shipped product policy, which currently
    /// keeps toast presentation disabled.
    public convenience init(
        clock: any Clock<Duration> = ContinuousClock(),
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.init(
            clock: clock,
            enabled: Self.defaultEnabled,
            diagnosticLog: diagnosticLog
        )
    }

    /// Internal injection keeps lifecycle tests able to exercise the dormant
    /// presenter without exposing a production toggle. The DEBUG gallery keeps
    /// its separate environment-gated entry point below.
    init(
        clock: any Clock<Duration>,
        enabled: Bool,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.clock = clock
        self.diagnosticLog = diagnosticLog
        self.isEnabled = enabled
        #if os(iOS)
        prefersExtendedDwell = {
            UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        }
        #else
        prefersExtendedDwell = { false }
        #endif
    }

    private static var defaultEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_TOAST_GALLERY"] == "1" {
            // Keep the gallery harness useful without making the shipped
            // product policy configurable.
            return true
        }
        #endif
        return shippedEnabled
    }

    /// Present a toast: shows it now if nothing is visible, refreshes and
    /// re-bumps the visible toast when the ``Toast/coalescingKey`` matches,
    /// and queues (FIFO, capped) otherwise. Dropped while the product policy
    /// keeps ``isEnabled`` false.
    public func present(_ toast: Toast) {
        guard isEnabled else {
            recordToastEvent(
                .toastDropped,
                toast: toast,
                detail: .toastStyle(diagnosticStyle(toast))
            )
            return
        }
        if let current = presented, current.toast.coalescingKey == toast.coalescingKey {
            presented = Presented(
                toast: toast.adoptingIdentity(of: current.toast),
                bumpCount: current.bumpCount + 1
            )
            recordToastEvent(
                .toastCoalesced,
                toast: current.toast,
                detail: .toastStyle(diagnosticStyle(toast))
            )
            restartAutoDismiss()
            return
        }
        if presented != nil || advanceTask != nil {
            if let index = queue.firstIndex(where: { $0.coalescingKey == toast.coalescingKey }) {
                queue[index] = toast.adoptingIdentity(of: queue[index])
                recordToastEvent(
                    .toastCoalesced,
                    toast: queue[index],
                    detail: .toastStyle(diagnosticStyle(toast))
                )
            } else {
                queue.append(toast)
                recordToastEvent(
                    .toastQueued,
                    toast: toast,
                    detail: .toastStyle(diagnosticStyle(toast))
                )
                if queue.count > Self.queueLimit {
                    let overflow = queue.count - Self.queueLimit
                    let dropped = queue.prefix(overflow)
                    for droppedToast in dropped {
                        recordToastEvent(
                            .toastDropped,
                            toast: droppedToast,
                            detail: .toastStyle(diagnosticStyle(droppedToast))
                        )
                    }
                    queue.removeFirst(overflow)
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
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            let toast = queue.remove(at: index)
            recordToastDismissed(toast, reason: .removedFromQueue)
        }
    }

    /// Dismiss any toast carrying `coalescingKey`, visible or queued. Used when
    /// the condition a persistent/status toast describes stops being true.
    public func dismiss(coalescingKey: String) {
        let removed = queue.filter { $0.coalescingKey == coalescingKey }
        queue.removeAll { $0.coalescingKey == coalescingKey }
        for toast in removed {
            recordToastDismissed(toast, reason: .removedFromQueue)
        }
        if presented?.toast.coalescingKey == coalescingKey {
            dismissCurrent()
        }
    }

    /// Dismiss the visible toast and advance to the next queued one after a
    /// short gap.
    public func dismissCurrent() {
        dismissCurrent(reason: .caller)
    }

    private func dismissCurrent(reason: DiagnosticToastDismissReason) {
        guard let toast = presented?.toast else { return }
        recordToastDismissed(toast, reason: reason)
        cancelAutoDismiss()
        presented = nil
        interactionHolds = 0
        scheduleAdvance()
    }

    /// Drop everything, including queued toasts. For hard context switches
    /// such as sign-out.
    public func dismissAll() {
        dismissAll(reason: .dismissAll)
    }

    private func dismissAll(reason: DiagnosticToastDismissReason) {
        if let toast = presented?.toast {
            recordToastDismissed(toast, reason: reason)
        }
        for toast in queue {
            recordToastDismissed(toast, reason: reason)
        }
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
        diagnosticLog?.recordAppEvent(
            .toastInteractionStarted,
            correlationID: toastID.uuidString,
            count: interactionHolds
        )
        cancelAutoDismiss()
    }

    /// Balances ``beginInteraction(for:)``. When the last hold releases, the
    /// full dwell restarts (forgiving: touching a toast means the user is
    /// reading it).
    public func endInteraction(for toastID: Toast.ID) {
        guard presented?.toast.id == toastID, interactionHolds > 0 else { return }
        interactionHolds -= 1
        diagnosticLog?.recordAppEvent(
            .toastInteractionEnded,
            correlationID: toastID.uuidString,
            count: interactionHolds
        )
        if interactionHolds == 0 {
            restartAutoDismiss()
        }
    }

    private func show(_ toast: Toast) {
        // A cancelled drag on the previous toast can leak a hold; interaction
        // is per-toast, so a fresh presentation always starts unheld.
        interactionHolds = 0
        presented = Presented(toast: toast, bumpCount: 0)
        recordToastEvent(
            .toastPresented,
            toast: toast,
            detail: .toastStyle(diagnosticStyle(toast))
        )
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
        dismissCurrent(reason: .automatic)
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

    private func recordToastEvent(
        _ kind: DiagnosticAppEventKind,
        toast: Toast,
        detail: DiagnosticAppEventDetail
    ) {
        diagnosticLog?.recordAppEvent(
            kind,
            correlationID: toast.id.uuidString,
            detail: detail
        )
    }

    private func recordToastDismissed(
        _ toast: Toast,
        reason: DiagnosticToastDismissReason
    ) {
        recordToastEvent(
            .toastDismissed,
            toast: toast,
            detail: .toastDismissReason(reason)
        )
    }

    private func diagnosticStyle(_ toast: Toast) -> DiagnosticToastStyle {
        switch toast.style {
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .failure: .failure
        }
    }
}
