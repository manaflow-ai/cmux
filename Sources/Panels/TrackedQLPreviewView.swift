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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `viewDidMoveToWindow` fires both on attach (window != nil) and detach
        // (window == nil). Only the detach transition deactivates the view.
        if window == nil {
            didDetachFromWindow = true
        }
    }
}
