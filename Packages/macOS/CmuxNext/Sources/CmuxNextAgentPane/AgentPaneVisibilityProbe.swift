import AppKit
import CmuxNextCompat

/// A zero-size subview of an agent pane that says when the pane may have come into sight: it
/// moved to a window, it or an ancestor was shown or hidden, or its window's occlusion changed. The pane's
/// ``AgentPaneFramePacer`` then delivers the frames it held while nobody could see the pane, and
/// Session Info's running-row wave starts or stops its loop. Kept off ``AgentPaneView``, whose
/// type is at its size limit.
@MainActor final class AgentPaneVisibilityProbe: NSView {
    var onChange: (@MainActor () -> Void)?
    private var occlusion: MainActorObservation?

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

    /// It or an ancestor was hidden: the pane's chat rows host stops handing batches at once.
    /// Every other owner reads visibility again on a change, and a hidden pane is a no-op for them.
    override func viewDidHide() {
        super.viewDidHide()
        onChange?()
    }

    /// `pane` moved to another superview (``AgentPaneView/viewDidMoveToSuperview()``): every probe in
    /// it and in its page hears it. A move within one window (Cmd-T adopting the parked New Tab spare
    /// into a pane, a parked painted page shown) sends no window move, and leaving the parking is
    /// what makes such a page seen (``NSView/nobodySees(painted:)``): its held frames, pushes and
    /// seen signal go in the turn of the move.
    static func superviewMoved(in pane: NSView) {
        for child in pane.subviews {
            if let probe = child as? AgentPaneVisibilityProbe {
                probe.onChange?()
                continue
            }
            for grandchild in child.subviews { (grandchild as? AgentPaneVisibilityProbe)?.onChange?() }
        }
    }
}
