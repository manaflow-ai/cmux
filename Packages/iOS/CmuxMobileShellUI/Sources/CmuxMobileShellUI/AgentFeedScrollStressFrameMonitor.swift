#if DEBUG && os(iOS)
import Foundation
import QuartzCore
import UIKit

/// DEBUG-only frame pacing collector for the Agent Feed stress fixture.
@MainActor
final class AgentFeedScrollStressFrameMonitor: NSObject {
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private(set) var frameIntervals: [TimeInterval] = []

    func start() {
        displayLink?.invalidate()
        previousTimestamp = nil
        frameIntervals.removeAll(keepingCapacity: true)

        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 60,
            preferred: 60
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func markerValue(state: String) -> String {
        let p95 = percentile95(frameIntervals)
        let maxInterval = frameIntervals.max() ?? 0
        let hitchCount = frameIntervals.lazy.filter { interval in
            interval > (1.0 / 60.0) * 1.5
        }.count
        let severeHitchCount = frameIntervals.lazy.filter { $0 >= 0.250 }.count
        return [
            "state=\(state)",
            "frames=\(frameIntervals.count)",
            "frame_p95_ms=\(milliseconds(p95))",
            "frame_max_ms=\(milliseconds(maxInterval))",
            "hitches=\(hitchCount)",
            "frame_ge250=\(severeHitchCount)",
        ].joined(separator: ";")
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        defer { previousTimestamp = link.timestamp }
        guard let previousTimestamp else { return }
        frameIntervals.append(link.timestamp - previousTimestamp)
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
