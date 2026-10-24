import AppKit
import CmuxNextCompat
import CmuxNextDesign

extension HomeNativeTranscriptView {
    /// Whether a person can see the transcript now, which is when it reports reads
    /// (`isVisibleToUser`): it shows (no hidden flag of its own or an ancestor's: a chat tab not
    /// selected, a parked workspace), part of it lies inside its ancestors' bounds (not a pane
    /// scrolled out of the strip), and its window is key and on screen.
    var isSeen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return false }
        return isWindowSeen(window)
    }

    func windowStateChanged() {
        let seen = isSeen
        guard transcript.isVisibleToUser != seen else { return }
        transcript.isVisibleToUser = seen
    }

    /// Hears the window's key and occlusion notices only while the transcript shows there: a hidden
    /// one (a parked workspace's chat, a tab not selected) costs nothing per Cmd-Tab, and reads its
    /// window when it shows again.
    func followWindow() {
        // A window in deallocation is no window: a weak reference to it aborts the runtime.
        let target = isHiddenOrHasHiddenAncestor ? nil : window.flatMap { $0.isBeingDeallocated ? nil : $0 }
        if target !== observedWindow || (target != nil) != isObservingWindow {
            observedWindow = target
            windowObservers = target.map { window in
                [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification]
                    .map { MainActorObservation($0, object: window) { [weak self] in self?.windowStateChanged() } }
            } ?? []
        }
        windowStateChanged()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        followWindow()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        followWindow()
    }

    /// AppKit asks for new tracking areas when the view's visible rect changes (an ancestor moved,
    /// a pane scrolled into or out of the strip, a resize).
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        windowStateChanged()
    }
}
