import Foundation
import Observation

/// Settles automatic process-title churn before it invalidates a sidebar row.
/// Publication waits for `settleInterval` of quiet, but is never deferred more
/// than `maxDeferralInterval` past the first unpublished change: an agent TUI
/// that animates its title faster than the settle interval must still surface
/// a fresh title periodically instead of freezing the row until it goes quiet.
/// The injected scheduler keeps both deadlines deterministic in tests, while
/// the async stream ties row observation to SwiftUI task cancellation.
@MainActor
@Observable
final class WorkspaceSidebarProcessTitleObservationModel {
    typealias Cancellation = @MainActor () -> Void
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Cancellation

    nonisolated static let defaultSettleInterval: TimeInterval = 0.5
    nonisolated static let extensionSidebarAggregateInterval: TimeInterval = 0.05
    /// Staleness bound as a multiple of the settle interval: 2 s for sidebar
    /// rows, 0.2 s for the extension-sidebar aggregate.
    nonisolated static let maxDeferralFactor: Double = 4

    @ObservationIgnored
    private(set) var changeGeneration: UInt64 = 0
    @ObservationIgnored
    private(set) var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored
    private var hasUnobservedChange = false
    @ObservationIgnored
    private var cancelSettleAction: Cancellation?
    @ObservationIgnored
    private var cancelDeferralDeadline: Cancellation?
    @ObservationIgnored
    private let settleInterval: TimeInterval
    @ObservationIgnored
    private let maxDeferralInterval: TimeInterval
    @ObservationIgnored
    private let schedule: Scheduler

    init(
        settleInterval: TimeInterval = defaultSettleInterval,
        maxDeferralInterval: TimeInterval? = nil,
        schedule: @escaping Scheduler = { delay, action in
            // Clamped far below Int.max nanoseconds (~292 years) so the Int
            // conversion cannot trap.
            let nanoseconds = min(max(0, delay) * 1_000_000_000.0, 9e18).rounded(.up)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            // Generous leeway lets deadlines of concurrently churning
            // workspaces land in one main-queue drain, so SwiftUI folds their
            // row refreshes into a single layout transaction.
            timer.schedule(deadline: .now() + .nanoseconds(Int(nanoseconds)), leeway: .milliseconds(100))
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    action()
                }
            }
            timer.resume()
            return {
                timer.setEventHandler {}
                timer.cancel()
            }
        }
    ) {
        self.settleInterval = max(0, settleInterval)
        self.maxDeferralInterval = max(0, maxDeferralInterval ?? settleInterval * Self.maxDeferralFactor)
        self.schedule = schedule
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            // A row's first pure snapshot and this subscription are not atomic:
            // an automatic title change in that gap found no observers and was
            // not scheduled. Replay it so the first subscriber refreshes once;
            // rows refresh by re-reading current state, so the replay is
            // idempotent.
            if hasUnobservedChange {
                hasUnobservedChange = false
                changeGeneration &+= 1
                continuation.yield(())
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.changeObservers[id] = nil
                    if self.changeObservers.isEmpty {
                        // A change that was still settling when the last
                        // observer tore down (row replacement) must survive as
                        // unobserved, or the replacement row never learns it.
                        if self.cancelSettleAction != nil || self.cancelDeferralDeadline != nil {
                            self.hasUnobservedChange = true
                        }
                        self.cancelPendingProcessTitleChange()
                    }
                }
            }
        }
    }

    func processTitleDidChange() {
        guard !changeObservers.isEmpty else {
            cancelPendingProcessTitleChange()
            hasUnobservedChange = true
            return
        }
        cancelSettleAction?()
        cancelSettleAction = schedule(settleInterval) { [weak self] in
            self?.publishSettledChange()
        }
        // Non-resetting staleness bound: changes spaced closer than the
        // settle interval reset the settle timer indefinitely, so without
        // this deadline a title animating at 10 Hz would never publish.
        if cancelDeferralDeadline == nil {
            cancelDeferralDeadline = schedule(maxDeferralInterval) { [weak self] in
                self?.publishSettledChange()
            }
        }
    }

    private func publishSettledChange() {
        cancelPendingProcessTitleChange()
        var delivered = false
        // Termination cleanup arrives through a separate MainActor task. If
        // that task is delayed by sidebar work, publication is the
        // authoritative reconciliation point so dead observers cannot make
        // every later title progressively more expensive.
        var terminatedObserverIDs: [UUID] = []
        for (id, continuation) in changeObservers {
            if case .terminated = continuation.yield(()) {
                terminatedObserverIDs.append(id)
                continue
            }
            delivered = true
        }
        for id in terminatedObserverIDs {
            changeObservers[id] = nil
        }
        if delivered {
            changeGeneration &+= 1
        } else {
            // Every registered continuation was already cancelled (row
            // replacement mid-settle, before the async registry cleanup ran):
            // nothing received the change, so keep it for the next subscriber.
            hasUnobservedChange = true
        }
    }

    func cancelPendingProcessTitleChange() {
        cancelSettleAction?()
        cancelSettleAction = nil
        cancelDeferralDeadline?()
        cancelDeferralDeadline = nil
    }
}
