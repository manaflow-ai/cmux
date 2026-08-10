#if DEBUG && os(iOS)
import CmuxMobileShellModel
import Foundation
import Observation
import QuartzCore

/// UI-test-only collector for real frame intervals and Feed row visibility latency.
@MainActor
@Observable
final class AgentFeedPerformanceProbe: NSObject {
    private(set) var markerValue = "state=idle;frames=0;visibility=0"

    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var burst: [MobileAgentFeedItem] = []
    @ObservationIgnored private var nextBurstIndex = 0
    @ObservationIgnored private var frameIntervals: [TimeInterval] = []
    @ObservationIgnored private var visibilityLatencies: [TimeInterval] = []
    @ObservationIgnored private var injectionTimes: [MobileAgentFeedItemID: CFTimeInterval] = [:]
    @ObservationIgnored private var inject: ((MobileAgentFeedItem) -> Void)?
    @ObservationIgnored private var previousFrameTimestamp: CFTimeInterval?

    func start(
        burst: [MobileAgentFeedItem],
        inject: @escaping (MobileAgentFeedItem) -> Void
    ) {
        displayLink?.invalidate()
        self.burst = burst
        self.inject = inject
        nextBurstIndex = 0
        frameIntervals = []
        visibilityLatencies = []
        injectionTimes = [:]
        previousFrameTimestamp = nil
        markerValue = "state=running;frames=0;visibility=0"
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        // Keep the probe's sampling clock deterministic. An unconstrained
        // display link may settle near 24 Hz for this otherwise static screen,
        // which makes a healthy callback cadence exceed the 33 ms stall gate.
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 60,
            preferred: 60
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func recordTopRowAppearance(_ id: MobileAgentFeedItemID) {
        guard let injectedAt = injectionTimes.removeValue(forKey: id) else { return }
        visibilityLatencies.append(CACurrentMediaTime() - injectedAt)
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        if let previousFrameTimestamp {
            frameIntervals.append(link.timestamp - previousFrameTimestamp)
        }
        previousFrameTimestamp = link.timestamp

        if burst.indices.contains(nextBurstIndex) {
            let item = burst[nextBurstIndex]
            nextBurstIndex += 1
            injectionTimes[item.id] = CACurrentMediaTime()
            inject?(item)
        }

        let finishedInjecting = nextBurstIndex == burst.count
        let collectedSettleFrames = frameIntervals.count >= burst.count + 30
        let observedEveryInsertion = visibilityLatencies.count == burst.count
        let reachedFrameDeadline = frameIntervals.count >= burst.count + 120
        if (finishedInjecting && collectedSettleFrames && observedEveryInsertion)
            || reachedFrameDeadline {
            link.invalidate()
            displayLink = nil
            inject = nil
            updateMarker(state: "complete")
        }
    }

    private func updateMarker(state: String) {
        markerValue = [
            "state=\(state)",
            "frames=\(frameIntervals.count)",
            "frame_p95_ms=\(milliseconds(percentile95(frameIntervals)))",
            "frame_max_ms=\(milliseconds(frameIntervals.max() ?? 0))",
            "frame_ge250=\(frameIntervals.lazy.filter { $0 >= 0.250 }.count)",
            "visibility=\(visibilityLatencies.count)",
            "visibility_p95_ms=\(milliseconds(percentile95(visibilityLatencies)))",
            "visibility_max_ms=\(milliseconds(visibilityLatencies.max() ?? 0))",
            "visibility_ge250=\(visibilityLatencies.lazy.filter { $0 >= 0.250 }.count)",
        ].joined(separator: ";")
    }

    private func percentile95(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }

    private func milliseconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f", interval * 1_000)
    }
}
#endif
