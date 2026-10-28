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
    /// One input of the keyed follower: the workspace set changed, or one workspace's status did.
    fileprivate enum StatusRunChange: Sendable {
        case membership
        case status(ObjectIdentifier, WorkspaceStatus?)
    }

    /// Follows every workspace's status entries and posts each finished run's notice. Keyed: one
    /// observation per workspace's status, so a status change in one workspace (a script that sets
    /// statuses in 50) costs that workspace only; the workspace set is observed through its
    /// revision, which moves only when a workspace comes or goes (CLAUDE.md "Go past Chrome where
    /// cmux is scripted").
    func followStatusRuns(_ store: DaemonStore) -> Task<Void, Never> {
        Task { [weak self] in // task-owner: start(services:) keeps the handle in tasks
            // concurrency-allow: one element per status change of a live workspace; this main-actor loop drains it every turn
            let (changes, sink) = AsyncStream<StatusRunChange>.makeStream()
            let membership = Task { // task-owner: cancelled when this follower ends
                for await _ in ObservationStream({ store.workspaceSetRevision }) { sink.yield(.membership) }
            }
            var watches: [ObjectIdentifier: (task: Task<Void, Never>, tracker: FinishedStatusRunTracker)] = [:]
            defer {
                membership.cancel()
                for watch in watches.values { watch.task.cancel() }
            }
            for await change in changes {
                guard let self else { return }
                switch change {
                case .membership:
                    let listed = Dictionary(store.workspaces.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
                    for (id, watch) in watches where listed[id] == nil {
                        watch.task.cancel()
                        watches[id] = nil
                    }
                    for (id, workspace) in listed where watches[id] == nil {
                        let task = Task { // task-owner: in watches, cancelled when the workspace leaves the set
                            for await status in ObservationStream({ workspace.status }) { sink.yield(.status(id, status)) }
                        }
                        watches[id] = (task, FinishedStatusRunTracker())
                    }
                case .status(let id, let status):
                    guard var watch = watches[id] else { continue }
                    self.statusRunVisits += 1
                    let notices = self.statusRunNotices(in: status.map { [$0] } ?? [], store: store, tracker: &watch.tracker)
                    watches[id] = watch
                    for notice in notices { self.postStatusRun(notice) }
                }
            }
        }
    }

    /// The notices for the runs that finished since `tracker`'s last look, under `behavior`.
    /// `visibility` says where a run's terminal is for the user (`visibility(of:)` when nil; tests
    /// pass their own); a run whose terminal this client has no tab for counts as not visible.
    func statusRunNotices(in store: DaemonStore, tracker: inout FinishedStatusRunTracker,
                          behavior: StatusBehaviorSettings = DesignSettings.shared.statusBehavior,
                          visibility: ((LocatedTab) -> TerminalVisibility)? = nil) -> [StatusRunNotice] {
        statusRunNotices(in: store.workspaces.compactMap(\.status), store: store, tracker: &tracker, behavior: behavior, visibility: visibility)
    }

    /// ``statusRunNotices(in:tracker:behavior:visibility:)`` over `statuses` only (one workspace's,
    /// from the keyed follower).
    func statusRunNotices(in statuses: [WorkspaceStatus], store: DaemonStore, tracker: inout FinishedStatusRunTracker,
                          behavior: StatusBehaviorSettings = DesignSettings.shared.statusBehavior,
                          visibility: ((LocatedTab) -> TerminalVisibility)? = nil) -> [StatusRunNotice] {
        tracker.update(statuses).compactMap { run in
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

    /// The tab of terminal `terminal` (`term_…`), wherever it is: O(1) lookups in the store's index.
    func locate(terminal: String, in store: DaemonStore) -> LocatedTab? {
        guard let tab = store.tab(terminalResource: ResourceID(rawValue: terminal)), let pane = store.pane(holding: tab),
              let workspace = store.workspace(containing: pane.handle) else { return nil }
        return LocatedTab(tab: tab, pane: pane, workspace: workspace)
    }
}
