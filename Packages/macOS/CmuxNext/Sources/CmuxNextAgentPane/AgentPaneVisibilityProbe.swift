import AppKit
import CmuxNextWakeups

/// A zero-size subview of an agent pane that says when the pane may have come into sight: it
/// moved to a window, it or an ancestor was shown, or its window's occlusion changed. The pane's
/// ``AgentPaneFramePacer`` then delivers the frames it held while nobody could see the pane.
/// Kept off ``AgentPaneView``, whose type is at its size limit.
@MainActor final class AgentPaneVisibilityProbe: NSView {
    var onChange: (@MainActor () -> Void)?
    /// The window's occlusion notice through its one ``WindowEvents`` observer, shared with every view in it.
    private var occlusion: EventSubscription?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusion = nil
        if let window {
            occlusion = WindowEvents.of(window).subscribe(NSWindow.didChangeOcclusionStateNotification, owner: "AgentPaneVisibilityProbe") { [weak self] in
                self?.onChange?()
            }
        }
        onChange?()
    }

    // visibility-walk-allow: the pacer's held frames go when AppKit shows the pane, the AppKit state its check reads (AgentPaneFramePacer.nobodySees); the call only asks that check, once per unhide
    override func viewDidUnhide() {
        super.viewDidUnhide()
        onChange?()
    }
}
