#if canImport(UIKit) && DEBUG
import CmuxConversationGeometry
import os
import UIKit

/// DEBUG lab: `CMUX_UITEST_CONVERSATION_AUTOSCROLL=<script>` scrolls the
/// transcript on its own (`ConversationAutoScrollScript`; `default` for the
/// standard sequence), so a scroll trace is recorded with the same motion
/// before and after a change, with no hands on the device. A display link
/// moves the content offset each frame; the steps go through the scroll
/// delegate callbacks a finger would (begin and end dragging, end
/// decelerating), so the transcript leaves and regains the bottom as it does
/// under a real drag. Each step is a signpost interval (subsystem
/// `com.cmux.conversation`, category `AutoScroll`) for the trace.
@MainActor
final class ConversationAutoScrollDriver {
    static let environmentKey = "CMUX_UITEST_CONVERSATION_AUTOSCROLL"

    private weak var controller: ConversationViewController?
    private let script: ConversationAutoScrollScript
    private var link: CADisplayLink?
    private var index = 0
    private var stepStart: CFTimeInterval = 0
    private var startOffset: CGFloat = 0
    private var interval: OSSignpostIntervalState?
    private let signposter = OSSignposter(subsystem: "com.cmux.conversation", category: "AutoScroll")

    init(controller: ConversationViewController, script: ConversationAutoScrollScript) {
        self.controller = controller
        self.script = script
    }

    /// The driver the environment asks for, or nil.
    static func fromEnvironment(controller: ConversationViewController) -> ConversationAutoScrollDriver? {
        guard let text = ProcessInfo.processInfo.environment[environmentKey], !text.isEmpty,
              let script = ConversationAutoScrollScript(parsing: text) else { return nil }
        return ConversationAutoScrollDriver(controller: controller, script: script)
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        index = -1
    }

    func stop() {
        link?.invalidate()
        link = nil
        endInterval()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let controller else { return stop() }
        let scrollView = controller.collectionView
        if index < 0 { begin(step: 0, at: link.timestamp, in: controller, scrollView: scrollView) }
        guard index < script.steps.count else { return stop() }
        let step = script.steps[index]
        let progress = step.progress(at: link.timestamp - stepStart)
        if case .hold = step {} else {
            let inset = scrollView.adjustedContentInset
            let top = -inset.top
            let bottom = controller.bottomOffset.y
            let y = min(bottom, max(top, startOffset - progress.distance))
            scrollView.contentOffset.y = y
            // A finger's drag updates the pin as it moves (isTracking or
            // isDecelerating in scrollViewDidScroll); the driver has neither.
            controller.isPinnedToBottom = controller.isNearBottom(tolerance: 44)
            if y == top || y == bottom, case .flick = step, progress.distance != 0 {
                return finish(step: step, at: link.timestamp, in: controller, scrollView: scrollView)
            }
        }
        if progress.finished { finish(step: step, at: link.timestamp, in: controller, scrollView: scrollView) }
    }

    private func finish(step: ConversationAutoScrollScript.Step, at time: CFTimeInterval, in controller: ConversationViewController, scrollView: UIScrollView) {
        switch step {
        case .drag:
            let next = index + 1 < script.steps.count ? script.steps[index + 1] : nil
            if case .flick = next {} else { controller.scrollViewDidEndDragging(scrollView, willDecelerate: false) }
        case .flick:
            controller.scrollViewDidEndDecelerating(scrollView)
        case .hold:
            break
        }
        begin(step: index + 1, at: time, in: controller, scrollView: scrollView)
    }

    private func begin(step next: Int, at time: CFTimeInterval, in controller: ConversationViewController, scrollView: UIScrollView) {
        endInterval()
        index = next
        stepStart = time
        startOffset = scrollView.contentOffset.y
        guard index < script.steps.count else { return stop() }
        let step = script.steps[index]
        switch step {
        case .drag:
            controller.scrollViewWillBeginDragging(scrollView)
        case .flick:
            let previous = index > 0 ? script.steps[index - 1] : nil
            if case .drag = previous {} else { controller.scrollViewWillBeginDragging(scrollView) }
            controller.scrollViewDidEndDragging(scrollView, willDecelerate: true)
        case .hold:
            break
        }
        let label = "\(index): \(String(describing: step))"
        interval = signposter.beginInterval("step", id: signposter.makeSignpostID(), "\(label)")
    }

    private func endInterval() {
        if let interval { signposter.endInterval("step", interval) }
        interval = nil
    }

    /// The display link holds its target strongly; the driver is held by
    /// the controller.
    @MainActor
    private final class DisplayLinkProxy: NSObject {
        weak var driver: ConversationAutoScrollDriver?
        init(_ driver: ConversationAutoScrollDriver) { self.driver = driver }
        @objc func tick(_ link: CADisplayLink) {
            guard let driver else { return link.invalidate() }
            driver.tick(link)
        }
    }
}
#endif
