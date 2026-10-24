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
    /// One input of the keyed follower: the workspace set changed, or one workspace record's status
    /// did. The record rides along, so a queued change of a record no longer followed can never be
    /// taken for another record's.
    fileprivate enum StatusRunChange: Sendable {
        case membership
        case status(WorkspaceModel, WorkspaceStatus?)
    }

    /// One followed workspace: its record (held, so its identity names it while followed), the
    /// observation of its status, and the runs it saw busy.
    fileprivate struct StatusRunWatch {
        let workspace: WorkspaceModel
        let task: Task<Void, Never>
        var tracker = FinishedStatusRunTracker()
    }

    /// Follows every workspace's status entries and posts each finished run's notice. Keyed: one
    /// observation per workspace's status, so a status change in one workspace (a script that sets
    /// statuses in 50) costs that workspace only; the workspace set is observed through its
    /// revision, which moves only when a workspace record comes or goes (a record replaced under
    /// its id included), never for a move (CLAUDE.md "Go past Chrome where cmux is scripted").
    ///
    /// A workspace's first status is read when it is followed, with its observation armed in the
    /// same step (`ObservationStream.current`), so a run that goes busy right after is seen busy.
    ///
    /// - Parameters:
    ///   - store: The store whose workspaces are followed.
    ///   - behavior: The notification settings, read once per status examined (tests pass their own).
    ///   - visibility: Where a run's terminal is for the user; nil reads ``visibility(of:)``.
    ///   - post: Where each notice goes; nil posts it to the daemon's ledger (``postStatusRun(_:)``).
    /// - Returns: The follower's task; cancelling it ends every observation it started.
    func followStatusRuns(_ store: DaemonStore,
                          behavior: @escaping @MainActor @Sendable () -> StatusBehaviorSettings = { DesignSettings.shared.statusBehavior },
                          visibility: (@MainActor @Sendable (LocatedTab) -> TerminalVisibility)? = nil,
                          post: (@MainActor @Sendable (StatusRunNotice) -> Void)? = nil) -> Task<Void, Never> {
        Task { [weak self] in // task-owner: start(services:) keeps the handle in tasks
            // concurrency-allow: one element per status change of a live workspace; this main-actor loop drains it every turn
            let (changes, sink) = AsyncStream<StatusRunChange>.makeStream()
            // Read now with tracking armed: a set change after this first pass is never lost.
            let (_, laterSets) = ObservationStream.current { store.workspaceSetRevision }
            let membership = Task { // task-owner: cancelled when this follower ends
                for await _ in laterSets { sink.yield(.membership) }
            }
            var watches: [ObjectIdentifier: StatusRunWatch] = [:]
            defer {
                membership.cancel()
                for watch in watches.values { watch.task.cancel() }
            }
            /// Feeds `status` to `watch`'s tracker and posts the runs it shows finished.
            @MainActor func examine(_ status: WorkspaceStatus?, _ watch: inout StatusRunWatch) {
                guard let service = self else { return }
                let notices = service.statusRunNotices(in: status.map { [$0] } ?? [], store: store, tracker: &watch.tracker,
                                                       behavior: behavior(), visibility: visibility)
                for notice in notices {
                    if let post { post(notice) } else { service.postStatusRun(notice) }
                }
            }
            /// Follows the listed records not followed yet and lets go of the ones no longer listed.
            @MainActor func reconcile() {
                let listed = Dictionary(store.workspaces.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
                for (id, watch) in watches where listed[id] == nil {
                    watch.task.cancel()
                    watches[id] = nil
                }
                for (id, workspace) in listed where watches[id] == nil {
                    let (status, later) = ObservationStream.current { workspace.status }
                    let task = Task { // task-owner: in watches, cancelled when the workspace leaves the set
                        for await status in later { sink.yield(.status(workspace, status)) }
                    }
                    var watch = StatusRunWatch(workspace: workspace, task: task)
                    examine(status, &watch)
                    watches[id] = watch
                }
            }
            reconcile()
            for await change in changes {
                guard self != nil else { return }
                switch change {
                case .membership:
                    reconcile()
                case .status(let workspace, let status):
                    let id = ObjectIdentifier(workspace)
                    guard var watch = watches[id], watch.workspace === workspace else { continue }
                    examine(status, &watch)
                    watches[id] = watch
                }
            }
        }
    }

    /// The notices for the runs of `statuses` (one workspace's, from the keyed follower) that
    /// finished since `tracker`'s last look, under `behavior`. `visibility` says where a run's
    /// terminal is for the user (`visibility(of:)` when nil; tests pass their own); a run whose
    /// terminal this client has no tab for counts as not visible.
    func statusRunNotices(in statuses: [WorkspaceStatus], store: DaemonStore, tracker: inout FinishedStatusRunTracker,
                          behavior: StatusBehaviorSettings = DesignSettings.shared.statusBehavior,
                          visibility: (@MainActor (LocatedTab) -> TerminalVisibility)? = nil) -> [StatusRunNotice] {
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
