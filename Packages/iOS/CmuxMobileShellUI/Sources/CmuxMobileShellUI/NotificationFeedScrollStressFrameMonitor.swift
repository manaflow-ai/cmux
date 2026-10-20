#if DEBUG && os(iOS)
import QuartzCore
import UIKit

/// DEBUG frame-pacing monitor for the profiling scroll driver: counts
/// display-link ticks arriving later than 1.5x the frame interval (the hitch
/// definition Instruments uses for "frame delay"). It exists only inside the
/// env-gated stress harness; production code paths never install it.
@MainActor
final class NotificationFeedScrollStressFrameMonitor: NSObject {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private(set) var frameCount = 0
    private(set) var hitchCount = 0
    private(set) var hitchTotal: CFTimeInterval = 0
    private(set) var worstHitch: CFTimeInterval = 0

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let lastTimestamp else { return }
        let delta = link.timestamp - lastTimestamp
        let expected = link.duration > 0 ? link.duration : 1.0 / 60.0
        frameCount += 1
        if delta > expected * 1.5 {
            hitchCount += 1
            hitchTotal += delta - expected
            worstHitch = max(worstHitch, delta - expected)
        }
    }
}
#endif
