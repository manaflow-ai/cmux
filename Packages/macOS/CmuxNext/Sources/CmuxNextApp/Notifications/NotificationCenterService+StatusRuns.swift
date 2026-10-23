import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings

/// Finished `cmux status run` notifications (plans/cmux-next/status-indicators.md section 2): the
/// CLI writes the run's status entry busy, then success or error with its exit code and duration,
/// and leaves the notification to the app, because only a client knows whether the user can see
/// the terminal. A run that took `status.runNotifyMinimumSeconds` or longer, in a terminal that
/// is not visible (or any terminal under `status.runNotifyWhenVisible`), posts a daemon
/// notification on the terminal's tab, as `cmux notify` does, so it marks the tab unread and
/// follows the notification settings.
extension NotificationCenterService {
    /// Follows every workspace's status entries and posts each finished run's notice.
    func followStatusRuns(_ store: DaemonStore) -> Task<Void, Never> {
        Task { [weak self] in // task-owner: start(services:) keeps the handle in tasks
            var tracker = FinishedStatusRunTracker()
            for await _ in ObservationStream({ store.workspaces.compactMap(\.status) }) {
                guard let self else { return }
                for notice in self.statusRunNotices(in: store, tracker: &tracker) { self.postStatusRun(notice) }
            }
        }
    }

    /// The notices for the runs that finished since `tracker`'s last look, under `behavior`.
    /// `visibility` says where a run's terminal is for the user (`visibility(of:)` when nil; tests
    /// pass their own); a run whose terminal this client has no tab for counts as not visible.
    func statusRunNotices(in store: DaemonStore, tracker: inout FinishedStatusRunTracker,
                          behavior: StatusBehaviorSettings = DesignSettings.shared.statusBehavior,
                          visibility: ((LocatedTab) -> TerminalVisibility)? = nil) -> [StatusRunNotice] {
        tracker.update(store.workspaces.compactMap(\.status)).compactMap { run in
            let located = run.terminal.flatMap { locate(terminal: $0, in: store) }
            let shown = located.map { visibility?($0) ?? self.visibility(of: $0) } ?? .hidden
            guard behavior.notifies(run, visibility: shown) else {
                note("status run \(run.key) finished: no notification (\(run.durationMs ?? 0) ms, visible \(shown.isVisible))")
                return nil
            }
            note("status run \(run.key) finished: notify tab=\(located?.tab.id ?? "-")")
            return StatusRunNotice(run, surface: located?.tab.surface, localizations: localizations)
        }
    }

    /// Posts `notice` to the daemon's ledger; its arrival brings the banner, sound and unread mark.
    func postStatusRun(_ notice: StatusRunNotice) {
        guard let services else { return }
        services.daemon.send("status run notification") { connection in
            try await connection.notify(title: notice.title, body: notice.body, level: notice.level, surface: notice.surface,
                                        source: NotificationSource.cli.rawValue)
        }
    }

    /// The tab of terminal `terminal` (`term_…`), wherever it is.
    func locate(terminal: String, in store: DaemonStore) -> LocatedTab? {
        for workspace in store.workspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                if let tab = pane.tabs.first(where: { $0.terminalResourceID?.rawValue == terminal }) {
                    return LocatedTab(tab: tab, pane: pane, workspace: workspace)
                }
            }
        }
        return nil
    }
}
