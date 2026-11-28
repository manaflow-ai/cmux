import class CmuxNextDesign.LaunchReveal

extension AgentTabStore {
    /// Whether `key`'s view in `pane` waits for the launch's first pane
    /// content (the focused terminal's first frame, `LaunchSettle`; other
    /// content once shown; the reveal deadline). A tab's first web view
    /// (`WKProcessPool`, `AgentPaneView.init`) costs about 150 ms on the main
    /// thread and would delay the focused pane's terminal, so a tab outside
    /// the focused pane waits while that pane shows a terminal that will
    /// draw (`focusedDraws`); a focused tab, a focused terminal whose host
    /// ended, or a launch whose focus is not known yet makes its view at
    /// once. `show` runs once, when the content arrives; the pane keeps what
    /// it shows (the launch snapshot) meanwhile.
    func deferAtLaunch(_ key: String, reveal: LaunchReveal, focusedPane: String?, pane: String, focusedDraws: Bool,
                       show: @escaping @MainActor () -> Void) -> Bool {
        guard focusedDraws, !reveal.isReady(.pane), views[resolve(key)] == nil, let focusedPane, focusedPane != pane else {
            return false
        }
        guard launchDeferred.insert(key).inserted else { return true }
        reveal.whenReady(.pane) { [weak self] in
            self?.launchDeferred.remove(key)
            show()
        }
        return true
    }
}
