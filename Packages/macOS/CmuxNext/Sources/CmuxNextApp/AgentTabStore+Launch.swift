import class CmuxNextDesign.LaunchReveal
import CmuxNextLaunch

extension AgentTabStore {
    /// Whether `key`'s view in `pane` waits at launch. A tab's first web view (`WKProcessPool`,
    /// `AgentPaneView.init`) costs about 150 ms on the main thread, and the first window frame never
    /// needs it: the pane draws the tab's page from the last quit meanwhile (`AgentPaneLaunchImages`).
    /// So every tab's view waits for the first window frame (`firstFrame`, #17587), and a tab
    /// outside the focused pane also for the launch's first pane content while that pane shows a
    /// terminal that will draw (`focusedDraws`; the focused terminal's first frame, `LaunchSettle`;
    /// the reveal deadline). A tab whose view exists, or one made after the first window frame in
    /// the focused pane, a focused terminal whose host ended or a launch whose focus is not known
    /// yet, makes its view at once. `show` runs once, when the view may be made (each held tab in a
    /// gate step of its own; it queues the pane for the presentation budget, one new view per
    /// display frame); the pane keeps what it shows (the launch snapshot, the saved page) meanwhile.
    func deferAtLaunch(_ key: String, reveal: LaunchReveal, firstFrame: FirstFrameGate, focusedPane: String?, pane: String,
                       focusedDraws: Bool, show: @escaping @MainActor () -> Void) -> Bool {
        guard views[resolve(key)] == nil else { return false }
        let waitsForFocusedTerminal = focusedDraws && !reveal.isReady(.pane) && focusedPane.map { $0 != pane } == true
        guard !firstFrame.isOpen || waitsForFocusedTerminal else { return false }
        guard launchDeferred.insert(key).inserted else { return true }
        firstFrame.whenOpen { [weak self] in
            guard let self else { return }
            guard waitsForFocusedTerminal else { return resumeDeferred(key, show) }
            reveal.whenReady(.pane) { [weak self] in self?.resumeDeferred(key, show) }
        }
        return true
    }

    /// A tab ``deferAtLaunch(_:reveal:firstFrame:focusedPane:pane:focusedDraws:show:)`` held may make its view now.
    private func resumeDeferred(_ key: String, _ show: @MainActor () -> Void) {
        launchDeferred.remove(key)
        show()
    }
}
