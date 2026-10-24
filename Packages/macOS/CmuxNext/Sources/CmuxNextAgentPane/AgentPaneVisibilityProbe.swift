import AppKit
import CmuxNextDesign

/// A zero-size subview of an agent pane that says when the pane may have come into sight: it
/// moved to a window, it or an ancestor was shown or unparked (``ParkingObserver``), or its window
/// was covered, minimized, ordered out or came back. The pane's ``AgentPaneFramePacer`` then delivers the frames it held while
/// nobody could see the pane. Kept off ``AgentPaneView``, whose type is at its size limit.
///
/// It hears its window's occlusion through the window's ``WindowOcclusionFamily`` (one observer per
/// window, PATTERNS.md P3), not an observer per pane.
@MainActor final class AgentPaneVisibilityProbe: NSView, WindowOcclusionFollowing, ParkingObserver {
    var onChange: (@MainActor () -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow !== window else { return }
        window.map { WindowOcclusionFamily.of($0) }?.remove(self)
        newWindow.map { WindowOcclusionFamily.of($0) }?.add(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onChange?()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onChange?()
    }

    func windowOcclusionDidChange() {
        onChange?()
    }

    func parkingDidChange() {
        onChange?()
    }
}
