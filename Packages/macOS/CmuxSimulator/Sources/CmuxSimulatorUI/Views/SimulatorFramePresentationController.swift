import Dispatch

/// Owns display-cadence frame copies for one remote surface.
///
/// Simulator and generic remote-frame views retain their own layers and geometry,
/// while this controller keeps their source, timer, visibility, and failure
/// lifecycle identical.
@MainActor
final class SimulatorFramePresentationController {
    private let presentationDidComplete:
        @MainActor (SimulatorFramePresentation) -> Void
    private var pipeline: SimulatorFramePresentationPipeline?
    private var presentationTimer: DispatchSourceTimer?
    private var presentationIsActive = false
    private var usesFramePublicationNotifications = false
    private var presentationIntervalNanoseconds =
        simulatorPresentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: nil
        )
    private var lastFrameRequestUptimeNanoseconds: UInt64?

    init(
        source: any SimulatorFrameSurfaceReading,
        presentationDidComplete:
            @escaping @MainActor (SimulatorFramePresentation) -> Void,
        sourceFailureDidOccur: @escaping @MainActor () -> Void
    ) {
        self.presentationDidComplete = presentationDidComplete
        pipeline = SimulatorFramePresentationPipeline(
            source: source,
            framePublicationDidArrive: { [weak self] in
                self?.schedulePublishedFrame()
            },
            presentationDidComplete: { [weak self] in
                self?.presentCompletedFrame()
            },
            sourceFailureDidOccur: { [weak self] in
                guard let self else { return }
                self.stopPresenting()
                self.pipeline = nil
                sourceFailureDidOccur()
            }
        )
    }

    /// Copies or presents the newest published frame without waiting for a timer.
    func presentLatestFrame() {
        guard let pipeline else { return }
        lastFrameRequestUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard let presentation = pipeline.displayTick() else { return }
        presentationDidComplete(presentation)
    }

    private func presentCompletedFrame() {
        guard let presentation = pipeline?.takeCompletedPresentation() else {
            return
        }
        presentationDidComplete(presentation)
    }

    /// Starts presentation at the host display cadence.
    func startPresenting(maximumFramesPerSecond: Int?) {
        guard !presentationIsActive, let pipeline else { return }
        presentationIsActive = true
        presentationIntervalNanoseconds = simulatorPresentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: maximumFramesPerSecond
        )
        if pipeline.setFramePublicationNotificationsEnabled(true) {
            usesFramePublicationNotifications = true
            presentLatestFrame()
            return
        }
        usesFramePublicationNotifications = false
        let timer = DispatchSource.makeTimerSource(
            flags: .strict,
            queue: .main
        )
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(presentationIntervalNanoseconds),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.presentLatestFrame()
        }
        presentationTimer = timer
        timer.activate()
    }

    /// Stops all publication wakeups while keeping the current source reusable.
    func stopPresenting() {
        presentationIsActive = false
        usesFramePublicationNotifications = false
        lastFrameRequestUptimeNanoseconds = nil
        presentationTimer?.setEventHandler(handler: nil)
        presentationTimer?.cancel()
        presentationTimer = nil
        pipeline?.setFramePublicationNotificationsEnabled(false)
    }

    private func schedulePublishedFrame() {
        guard presentationIsActive, usesFramePublicationNotifications else {
            return
        }
        guard presentationTimer == nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = UInt64(presentationIntervalNanoseconds)
        let elapsed = lastFrameRequestUptimeNanoseconds.map {
            now >= $0 ? now - $0 : interval
        } ?? interval
        guard elapsed < interval else {
            presentLatestFrame()
            return
        }
        let delay = Int(interval - elapsed)
        let timer = DispatchSource.makeTimerSource(
            flags: .strict,
            queue: .main
        )
        timer.schedule(
            deadline: .now() + .nanoseconds(delay),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            timer?.setEventHandler(handler: nil)
            timer?.cancel()
            self.presentationTimer = nil
            guard self.presentationIsActive,
                  self.usesFramePublicationNotifications else { return }
            self.presentLatestFrame()
        }
        presentationTimer = timer
        timer.activate()
    }

    /// Rebuilds fallback cadence after the host display changes.
    func rebuildPresentationCadence(
        isVisible: Bool,
        maximumFramesPerSecond: Int?
    ) {
        stopPresenting()
        guard isVisible else { return }
        startPresenting(maximumFramesPerSecond: maximumFramesPerSecond)
    }

    /// Permanently releases the frame source and timer.
    func invalidate() {
        stopPresenting()
        let pipeline = pipeline
        self.pipeline = nil
        pipeline?.invalidate()
    }
}
