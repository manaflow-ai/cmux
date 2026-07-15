/// Coalesces display ticks into one off-main frame copy at a time.
///
/// A blocked read can strand one detached task for this source, but the actor
/// stays responsive and never starts a second read until the first completes.
@MainActor
final class SimulatorFramePresentationPipeline {
    private let source: any SimulatorFrameSurfaceReading
    private var isActive = true
    private var copyIsInFlight = false
    private var lastCopiedSequence: UInt64?
    private var newestCompletedPresentation: SimulatorFramePresentation?

    init(source: any SimulatorFrameSurfaceReading) {
        self.source = source
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
        newestCompletedPresentation = nil
    }

    private func requestCopy() {
        guard !copyIsInFlight,
              source.hasPublishedFrame(after: lastCopiedSequence) else { return }
        copyIsInFlight = true
        let source = self.source
        let sequence = lastCopiedSequence
        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = await source.copyLatestFrame(after: sequence)
            let presentation = snapshot.flatMap(SimulatorFramePresentation.init(snapshot:))
            await MainActor.run {
                self?.copyDidComplete(
                    presentation: presentation,
                    observedSequence: snapshot?.sequence
                )
            }
        }
    }

    private func copyDidComplete(
        presentation: SimulatorFramePresentation?,
        observedSequence: UInt64?
    ) {
        copyIsInFlight = false
        guard isActive else { return }
        if let observedSequence,
           lastCopiedSequence.map({ observedSequence > $0 }) ?? true {
            lastCopiedSequence = observedSequence
        }
        if let presentation,
           newestCompletedPresentation.map({ presentation.sequence > $0.sequence }) ?? true {
            newestCompletedPresentation = presentation
        }
    }
}
