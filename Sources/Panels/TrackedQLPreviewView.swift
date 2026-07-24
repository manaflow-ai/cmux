import Quartz

/// `QLPreviewView` subclass that records when AppKit removes it from its window.
///
/// QuickLook moves a preview view into its deactivated internal state when the
/// view leaves the window hierarchy. Once deactivated, assigning a non-nil
/// preview item trips a fatal QuickLook assertion
/// (`-[QLPreviewView setPreviewItem:blockingUntilLoading:timeoutDate:transition:]:`
/// `item == nil || _reserved->internalState != QLPreviewDeactivatedInternalState`)
/// which calls `abort()`. There is no public API to read that internal state, so
/// we track window detachment ourselves and let the owning container retire a
/// detached instance instead of reusing it.
final class TrackedQLPreviewView: QLPreviewView {
    private(set) var didDetachFromWindow = false
    private var hasAttachedToWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `viewDidMoveToWindow` fires both on attach (window != nil) and detach
        // (window == nil). An initial move into an off-window container is not
        // a detach transition and must not retire the preview before mounting.
        if window != nil {
            hasAttachedToWindow = true
        } else if hasAttachedToWindow {
            didDetachFromWindow = true
        }
    }
}
