import CmuxNextDaemon

extension PaneController {
    /// A new record of this pane under the same public id (a resync rebuilt it): the layout
    /// keeps this controller, its strip and its views, so the model moves to the new record and
    /// the observation follows it. An optimistic split's echo never comes here: the daemon's
    /// pane updates the provisional record in place (`DaemonStore.confirmedPane`).
    func adopt(_ model: PaneModel) {
        guard model !== pane else { return }
        #if DEBUG
        DebugLayoutCounters.note("pane adopt", #fileID, #line)
        #endif
        pane = model
        syncDrawnCells()
        observe()
    }
}
