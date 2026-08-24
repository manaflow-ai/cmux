#if DEBUG
import AppKit

/// Debug-only view that reports attachment and effective-appearance lifecycle changes.
@MainActor
final class BrowserDownloadsPopoverAppearanceWindowObservingView: NSView {
    var onWindow: (@MainActor (NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowIfAttached()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reportWindowIfAttached()
    }

    func reportWindowIfAttached() {
        guard let window else { return }
        onWindow?(window)
    }
}
#endif
