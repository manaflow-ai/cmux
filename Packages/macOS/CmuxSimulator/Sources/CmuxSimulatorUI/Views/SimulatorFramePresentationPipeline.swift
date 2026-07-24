import Foundation

/// Coalesces display ticks into one off-main frame copy at a time.
///
/// A blocked read can strand one detached task for this source, but the actor
/// stays responsive and never starts a second read until the first completes.
@MainActor
final class SimulatorFramePresentationPipeline {
    private let source: any SimulatorFrameSurfaceReading
    private let presentationDidComplete: @MainActor () -> Void
    private nonisolated let framePublicationWakeup = SimulatorFramePublicationWakeup()
    private var isActive = true
    private var copyIsInFlight = false
    private var publicationArrivedWhileCopying = false
    private var framePublicationHandlerIsInstalled = false
    private var lastCopiedSequence: UInt64?
    private var newestCompletedPresentation: SimulatorFramePresentation?

    init(
        source: any SimulatorFrameSurfaceReading,
        presentationDidComplete: @escaping @MainActor () -> Void
    ) {
        self.source = source
        self.presentationDidComplete = presentationDidComplete
        setFramePublicationNotificationsEnabled(true)
    }

    func displayTick() -> SimulatorFramePresentation? {
        guard isActive else { return nil }
        let presentation = newestCompletedPresentation
        newestCompletedPresentation = nil
        requestCopy()
        return presentation
    }

    func invalidate() {
        isActive = false
        setFramePublicationNotificationsEnabled(false)
        newestCompletedPresentation = nil
    }

    /// Enables event-driven wakeups when the source can signal publications.
    ///
    /// Returns `true` when the caller can omit its display-cadence fallback.
    @discardableResult
    func setFramePublicationNotificationsEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            if framePublicationHandlerIsInstalled {
                source.setFramePublicationHandler(nil)
            }
            framePublicationHandlerIsInstalled = false
            return false
        }
        guard isActive else { return false }
        if framePublicationHandlerIsInstalled { return true }
        let wakeup = framePublicationWakeup
        framePublicationHandlerIsInstalled = source.setFramePublicationHandler {
            [weak self] in
            guard wakeup.recordSignal() else { return }
            Task { @MainActor [weak self] in
                guard let self else {
                    wakeup.abandonDelivery()
                    return
                }
                self.deliverFramePublicationWakeup(wakeup)
            }
        }
        return framePublicationHandlerIsInstalled
    }

    private func requestCopy() {
        guard !copyIsInFlight,
              source.hasPublishedFrame(after: lastCopiedSequence) else { return }
        copyIsInFlight = true
        let source = self.source
        let sequence = lastCopiedSequence
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let snapshot = await source.copyLatestFrame(after: sequence)
                return (
                    presentation: snapshot.flatMap(SimulatorFramePresentation.init(snapshot:)),
                    observedSequence: snapshot?.sequence
                )
            }.value
            self?.copyDidComplete(
                presentation: result.presentation,
                observedSequence: result.observedSequence
            )
        }
    }

    private func framePublicationDidFire() {
        guard isActive, framePublicationHandlerIsInstalled else { return }
        if copyIsInFlight {
            publicationArrivedWhileCopying = true
            return
        }
        requestCopy()
    }

    private func deliverFramePublicationWakeup(
        _ wakeup: SimulatorFramePublicationWakeup
    ) {
        framePublicationDidFire()
        guard wakeup.deliveryDidFinish() else { return }
        Task { @MainActor [weak self] in
            guard let self else {
                wakeup.abandonDelivery()
                return
            }
            self.deliverFramePublicationWakeup(wakeup)
        }
    }

    private func copyDidComplete(
        presentation: SimulatorFramePresentation?,
        observedSequence: UInt64?
    ) {
        copyIsInFlight = false
        guard isActive else { return }
        let shouldRetry = publicationArrivedWhileCopying
        publicationArrivedWhileCopying = false
        if let observedSequence,
           lastCopiedSequence.map({ observedSequence > $0 }) ?? true {
            lastCopiedSequence = observedSequence
        }
        if let presentation,
           newestCompletedPresentation.map({ presentation.sequence > $0.sequence }) ?? true {
            newestCompletedPresentation = presentation
            presentationDidComplete()
        }
        if shouldRetry {
            requestCopy()
        }
    }
}

private final class SimulatorFramePublicationWakeup: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveryIsScheduled = false
    private var signalArrivedWhileScheduled = false

    func recordSignal() -> Bool {
        lock.withLock {
            guard !deliveryIsScheduled else {
                signalArrivedWhileScheduled = true
                return false
            }
            deliveryIsScheduled = true
            return true
        }
    }

    func deliveryDidFinish() -> Bool {
        lock.withLock {
            guard signalArrivedWhileScheduled else {
                deliveryIsScheduled = false
                return false
            }
            signalArrivedWhileScheduled = false
            return true
        }
    }

    func abandonDelivery() {
        lock.withLock {
            deliveryIsScheduled = false
            signalArrivedWhileScheduled = false
        }
    }
}
