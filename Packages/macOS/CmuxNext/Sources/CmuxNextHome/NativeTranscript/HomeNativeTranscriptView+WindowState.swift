import AppKit
import CmuxNextCompat
import CmuxNextDesign

extension HomeNativeTranscriptView {
    /// Whether a person can see the transcript now, which is when it reports reads
    /// (`isVisibleToUser`): its host presents it on screen (``isPresented``: for a conversation tab,
    /// a pane the layout reports on screen shows the tab), it shows (no hidden flag of its own or
    /// an ancestor's), and its window is key and on screen.
    ///
    /// No geometry: a view's `visibleRect` is what its ancestors show in its own coordinates, so it
    /// is not empty for a pane moved out of the strip when no ancestor clips (the default since the
    /// macOS 14 SDK), and it ignores the strip's layer masks (a pane under a docked column, clipped
    /// by its nested area window) and alpha. The layout's pane presence knows them all.
    var isSeen: Bool {
        guard let window, isPresented, !isHiddenOrHasHiddenAncestor else { return false }
        return isWindowSeen(window)
    }

    func windowStateChanged() {
        let seen = isSeen
        guard transcript.isVisibleToUser != seen else { return }
        transcript.isVisibleToUser = seen
    }

    /// Hears the window's key and occlusion notices only while the transcript is presented and
    /// shows there: a hidden or off-screen one (a parked workspace's chat, a tab not selected, a pane
    /// scrolled out of the strip) costs nothing per Cmd-Tab, and reads its window when it shows
    /// again.
    func followWindow() {
        // A window in deallocation is no window: a weak reference to it aborts the runtime.
        let target = !isPresented || isHiddenOrHasHiddenAncestor ? nil : window.flatMap { $0.isBeingDeallocated ? nil : $0 }
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
}
