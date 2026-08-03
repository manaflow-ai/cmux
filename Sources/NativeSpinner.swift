#if DEBUG
import AppKit

@MainActor
final class NativeSpinner: NSProgressIndicator {
    init(threaded: Bool, controlSize: NSControl.ControlSize = .small) {
        super.init(frame: .zero)
        style = .spinning
        self.controlSize = controlSize
        isIndeterminate = true
        isDisplayedWhenStopped = false
        usesThreadedAnimation = threaded
        startAnimation(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif
