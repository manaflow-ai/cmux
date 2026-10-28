public import CmuxNextSignposts

extension CEFEngine {
    /// Where Chromium pages' hangs go as stability events, process-wide like ``crashLog`` (the App sets its reporting one).
    public var rendererStability: RendererStability {
        get { CEFRuntime.shared.rendererStability }
        set { CEFRuntime.shared.rendererStability = newValue }
    }
}

extension RendererStability {
    /// Follows a Chromium tab's "Page unresponsive" state across one change of its state machine
    /// (the tab's `machine` setter): the state turning on opens the tab's span, turning off ends it with how it ended
    /// (``BrowserTabStateMachine/unresponsiveEnd(from:to:)``). The renderer's RENDER_UNRESPONSIVE / RESPONSIVE events,
    /// the person's Wait, a renderer end and a new navigation all reach the state through the reducer, so this one
    /// place sees every start and end but a close (the tab's `isClosed`, and its browser's end). A closed tab stays
    /// registered until Chromium destroys its browser, so a hang it reports then opens no span. A change that leaves
    /// the state as it was records nothing, so the setter calls it on every apply.
    ///
    /// - Parameters:
    ///   - old: The state before the apply.
    ///   - new: The state after it.
    ///   - tab: The tab; a tab showing a cmux page (`pageThemeSurface` set) is the ``Surface/page`` surface.
    func tabStateChanged(from old: BrowserTabState, to new: BrowserTabState, of tab: CEFTab) {
        guard old.isUnresponsive != new.isUnresponsive else { return }
        if new.isUnresponsive {
            guard !tab.isClosed else { return }
            unresponsiveShown(ObjectIdentifier(tab), surface: tab.pageThemeSurface == nil ? .browserTab : .page)
        } else {
            unresponsiveEnded(ObjectIdentifier(tab), BrowserTabStateMachine.unresponsiveEnd(from: old, to: new))
        }
    }
}
