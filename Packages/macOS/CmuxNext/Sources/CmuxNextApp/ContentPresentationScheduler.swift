import CmuxNextControl
import CmuxNextDaemonService

extension ContentPresentationScheduler {
    convenience init(frames: any ControlFrameSource = FrameBatcher(owner: "ContentPresentation")) {
        self.init(frameSource: frames, measure: { span, body in BenchSpans.measure(span, body) })
    }
}
