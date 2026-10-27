import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The window's content view: the tool's screen on its surface.
final class OnboardingHostView: NSView {
    init(model: OnboardingModel, mainWork: MainWorkScheduler) {
        super.init(frame: NSRect(origin: .zero, size: OnboardingMetrics.windowSize))
        autoresizingMask = [.width, .height]
        let screen = model.step.screen
        let content = screen.makeContent(OnboardingStepContext(model: model, mainWork: mainWork))
        let surface = OnboardingSurfaceView(surface: screen.surface, content: content, mainWork: mainWork)
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
