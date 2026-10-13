import CmuxNextDaemon

extension PaneController {
    /// The daemon's pane replaced the provisional one under the same public id (a split,
    /// cx-ry0y): the layout keeps this controller, its strip and its views, so the model moves
    /// to the daemon's pane and the observation follows it. Observing the provisional model kept
    /// its tabs, so focus waited for a daemon surface the strip never listed.
    func adopt(_ model: PaneModel) {
        guard model !== pane else { return }
        pane = model
        observe()
    }
}
