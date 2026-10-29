#if os(iOS)
import CMUXMobileCore
import UIKit

/// Owns no view state; the display link runs only during visible Feed scrolling.
@MainActor
final class AgentFeedScrollMonitor {
    private let observer: (any MobileFeedPerformanceObserving)?
    private var link: CADisplayLink?

    init(observer: (any MobileFeedPerformanceObserving)?) {
        self.observer = observer
    }

    func setScrolling(_ active: Bool) {
        observer?.setScrolling(active)
        guard active, observer?.isSamplingEnabled == true else {
            stop()
            return
        }
        guard link == nil else { return }
        let target = AgentFeedDisplayLinkTarget(monitor: self)
        let link = CADisplayLink(target: target, selector: #selector(AgentFeedDisplayLinkTarget.tick(_:)))
        // Preserve the system-selected refresh cadence, including ProMotion.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func tick(_ link: CADisplayLink) {
        guard observer?.isSamplingEnabled == true else {
            stop()
            return
        }
        observer?.callback(
            at: CACurrentMediaTime(),
            expectedInterval: link.targetTimestamp - link.timestamp
        )
    }

    func stop() {
        link?.invalidate()
        link = nil
        observer?.setScrolling(false)
    }
}
#endif
