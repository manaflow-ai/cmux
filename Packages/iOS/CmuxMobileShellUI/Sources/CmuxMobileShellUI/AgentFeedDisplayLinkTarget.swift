#if os(iOS)
import UIKit

/// Breaks CADisplayLink's strong target cycle when its owning view disappears.
@MainActor
final class AgentFeedDisplayLinkTarget: NSObject {
    private weak var monitor: AgentFeedScrollMonitor?

    init(monitor: AgentFeedScrollMonitor) { self.monitor = monitor }

    @objc func tick(_ link: CADisplayLink) {
        guard let monitor else {
            link.invalidate()
            return
        }
        monitor.tick(link)
    }
}
#endif
