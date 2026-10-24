import AppKit
import CmuxNextCompat

/// A zero-size subview of an agent pane that says when the pane may have come into sight: it
/// moved to a window, it or an ancestor was shown, or its window's occlusion changed. The pane's
/// ``AgentPaneFramePacer`` then delivers the frames it held while nobody could see the pane.
/// Kept off ``AgentPaneView``, whose type is at its size limit.
@MainActor final class AgentPaneVisibilityProbe: NSView {
    var onChange: (@MainActor () -> Void)?
    private var occlusion: MainActorObservation?

    // cx-t7hu: nonisolated, so a release (inside an action's task-local scope, or off the main
    // thread) runs no runtime hop; an implicit deinit is isolated in this target. The occlusion
    // observer (a MainActorObservation) is removed on the releasing thread.
    nonisolated deinit {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusion = nil
        if let window {
            occlusion = MainActorObservation(NSWindow.didChangeOcclusionStateNotification, object: window) { [weak self] in
                self?.onChange?()
            }
        }
        onChange?()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onChange?()
    }
}
