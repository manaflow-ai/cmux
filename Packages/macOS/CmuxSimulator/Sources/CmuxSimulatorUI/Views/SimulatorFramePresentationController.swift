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

    init(
        source: any SimulatorFrameSurfaceReading,
        presentationDidComplete:
            @escaping @MainActor (SimulatorFramePresentation) -> Void,
        sourceFailureDidOccur: @escaping @MainActor () -> Void
    ) {
        self.presentationDidComplete = presentationDidComplete
        pipeline = SimulatorFramePresentationPipeline(
            source: source,
            framePublicationNotificationsEnabled: false,
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
        guard let presentation = pipeline?.displayTick() else { return }
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
        guard presentationTimer == nil, let pipeline else { return }
        pipeline.setFramePublicationNotificationsEnabled(false)
        let interval = simulatorPresentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: maximumFramesPerSecond
        )
        let timer = DispatchSource.makeTimerSource(
            flags: .strict,
            queue: .main
        )
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(interval),
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
        presentationTimer?.setEventHandler(handler: nil)
        presentationTimer?.cancel()
        presentationTimer = nil
        pipeline?.setFramePublicationNotificationsEnabled(false)
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
