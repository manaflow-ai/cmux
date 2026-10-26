public import CmuxNextActions
public import CmuxNextMetrics

/// Folds every action run into a latency histogram per report id and entrypoint, off the main
/// actor: the Release side of the per-action budget. ``ActionBudgetReporter`` feeds it the
/// monitor's batches; the opt-in nightly report reads ``snapshot(dropped:)``.
///
/// The same fold records the actions' field histograms (p09-observability task 056; Chrome reads latency and
/// smoothness per interaction the same way, cc/metrics/event_latency_tracker.cc and
/// cc/metrics/frame_sequence_tracker.cc): `action.commit.<entrypoint>` for every committed run, `action.cmd_t`,
/// `action.cmd_n` and `action.cmd_w` for the key runs of New Tab, New Window and Close Tab (``command(for:)``),
/// and `action.missed_frames.<command>` once that run's commit window has closed
/// (``noteCommitWindow(missedFrames:closedAtUptimeNanos:)``). None of it adds work to the action's turn: the runs
/// reach the ledger after the commit they are timed to.
public actor ActionBudgetLedger {
    /// The histogram's bucket edges in milliseconds (fixed, so reports from every build and day
    /// add up, and p95 / p99 come out of the counts): a run counts in the first edge it does not
    /// exceed; a run over 250 ms counts in the last bucket.
    public static let bucketEdgesMilliseconds: [Double] = [2, 4, 6, 8, 10, 12, 16, 24, 33, 50, 100, 250]

    /// Rows kept; the catalog is finite (about 1,200 actions times 8 entrypoints at most) and
    /// uncataloged ids fold into two report ids, so this bound is never reached in practice.
    public static let maxRows = 4_096

    /// The longest a commit window may close after its run's commit and still count for it: a window spans the
    /// 3 refreshes after the commit (`FrameSequenceTracker.commitWindowFrames`) and closes at the first frame
    /// after them, so only a hung main thread takes longer, and the hang histograms own that.
    public static let commitWindowSpanNanos: UInt64 = 1_000_000_000
    /// Key runs of New Tab, New Window and Close Tab kept while they wait for their commit window.
    static let maxPendingCommands = 16
    /// Commit windows kept until a later run settles them (runs reach the ledger a batch at a time).
    static let maxPendingWindows = 256

    private struct Key: Hashable {
        let id: String
        let entrypoint: ActionEntrypoint
    }

    /// A key run of a timed command whose commit window has not been seen yet.
    private struct PendingCommand {
        let command: HistogramID.Command
        /// `CLOCK_UPTIME_RAW` nanoseconds at the end of the run's commit.
        let committedAt: UInt64
    }

    /// A closed commit window whose run has not been folded yet.
    private struct PendingWindow {
        let missedFrames: Int64
        /// `CLOCK_UPTIME_RAW` nanoseconds when the window closed.
        let closedAt: UInt64
    }

    /// The budget, in milliseconds.
    public let budgetMilliseconds: Double
    private let naming: ActionReportNaming
    private let metrics: Metrics
    private var rows: [Key: ActionBudgetRow] = [:]
    private var total = 0
    private var excluded = 0
    private var over = 0
    /// Oldest first, by commit.
    private var commands: [PendingCommand] = []
    /// Oldest first, by close.
    private var windows: [PendingWindow] = []
    /// The end of the newest commit folded. Commits end in run order, so a window that closed before it has met
    /// every run it could belong to.
    private var newestCommit: UInt64 = 0

    /// - Parameters:
    ///   - budgetMilliseconds: The monitor's budget.
    ///   - naming: Maps an action to its report id (catalog id, `custom` or `extension`).
    ///   - metrics: Where the field histograms go (the app's metrics file by default; tests pass their own).
    public init(budgetMilliseconds: Double, naming: ActionReportNaming, metrics: Metrics = Metrics()) {
        self.budgetMilliseconds = budgetMilliseconds
        self.naming = naming
        self.metrics = metrics
    }

    /// The timed command whose `action.cmd_*` and `action.missed_frames.*` histograms `id`'s key runs go to: the
    /// catalog's New Tab (Cmd-T), New Window (`cmd_n`, the catalog's "Cmd-N, a new window"; Shift-Cmd-N in cmux)
    /// and Close Tab (Cmd-W). Keyed by action, so a rebound shortcut still counts as its action.
    public static func command(for id: ActionID) -> HistogramID.Command? {
        switch id.rawValue {
        case "newTab.default": .cmdT
        case "newWindow": .cmdN
        case "closeTab": .cmdW
        default: nil
        }
    }

    /// Folds `runs` in.
    public func note(_ runs: [ActionTimingSample]) {
        for run in runs { note(run) }
        matchCommitWindows()
    }

    /// A commit window closed with `missedFrames` refreshes that showed no frame (the `dropped` count of a
    /// `FrameSequenceTracker` commit window). It counts for the newest New Tab, New Window or Close Tab key run
    /// that committed before it closed, at most ``commitWindowSpanNanos`` earlier. Runs reach the ledger in
    /// batches after the window, so it is recorded once a run that committed after the close is folded; a window
    /// with no such command run records nothing.
    ///
    /// - Parameters:
    ///   - missedFrames: The window's dropped frames.
    ///   - closedAtUptimeNanos: `CLOCK_UPTIME_RAW` nanoseconds at the close (``ActionBudgetMonitor/now()``).
    public func noteCommitWindow(missedFrames: Int, closedAtUptimeNanos: UInt64) {
        if windows.count == Self.maxPendingWindows { windows.removeFirst() }
        let window = PendingWindow(missedFrames: Int64(clamping: max(missedFrames, 0)), closedAt: closedAtUptimeNanos)
        let position = windows.lastIndex { $0.closedAt <= closedAtUptimeNanos }.map { $0 + 1 } ?? 0
        windows.insert(window, at: position)
        matchCommitWindows()
    }

    private func note(_ run: ActionTimingSample) {
        total += 1
        guard run.outcome == .committed else {
            excluded += 1
            return
        }
        recordFieldHistograms(run)
        let ms = run.milliseconds
        if ms > budgetMilliseconds { over += 1 }
        let edges = Self.bucketEdgesMilliseconds
        let bucket = edges.firstIndex { ms <= $0 } ?? edges.count
        let key = Key(id: naming.reportID(for: run.id), entrypoint: run.entrypoint)
        if var row = rows[key] {
            row.count += 1
            row.buckets.modify(checked: bucket) { $0 += 1 }
            row.maxMilliseconds = max(row.maxMilliseconds, ms)
            rows[key] = row
        } else if rows.count < Self.maxRows {
            var buckets = [Int](repeating: 0, count: edges.count + 1)
            buckets.modify(checked: bucket) { $0 = 1 }
            rows[key] = ActionBudgetRow(id: key.id, entrypoint: run.entrypoint.rawValue, count: 1, buckets: buckets, maxMilliseconds: ms)
        }
    }

    /// `action.commit.<entrypoint>` (start to commit) and, for a timed command's key run, `action.cmd_*` from the
    /// key event to the commit; that run then waits for its commit window.
    private func recordFieldHistograms(_ run: ActionTimingSample) {
        let microseconds = Int64(clamping: run.nanos / 1_000)
        metrics.record(.actionCommit(HistogramID.Entrypoint(run.entrypoint)), microseconds)
        let committedAt = run.startUptimeNanos &+ run.nanos
        newestCommit = max(newestCommit, committedAt)
        guard run.entrypoint == .key, let command = Self.command(for: run.id) else { return }
        let fromInput = run.inputToCommitMilliseconds.flatMap { Int64(exactly: ($0 * 1_000).rounded()) } ?? microseconds
        metrics.record(.actionCommand(command), fromInput)
        if commands.count == Self.maxPendingCommands { commands.removeFirst() }
        commands.append(PendingCommand(command: command, committedAt: committedAt))
    }

    /// Pairs each settled window, oldest first, with the newest pending command committed before it closed, and
    /// drops a settled window with none. A window settles once a run that committed after it closed is folded:
    /// runs commit in order, so every run it could belong to is folded by then. A later command in the same window
    /// takes it from an earlier one (the window counts the frames after both, once), and the earlier one is dropped.
    private func matchCommitWindows() {
        while let window = windows.first, window.closedAt <= newestCommit {
            windows.removeFirst()
            commands.removeAll { $0.committedAt &+ Self.commitWindowSpanNanos < window.closedAt }
            guard let latest = commands.last(where: { $0.committedAt <= window.closedAt }) else { continue }
            metrics.record(.actionMissedFrames(latest.command), window.missedFrames)
            commands.removeAll { $0.committedAt <= latest.committedAt }
        }
    }

    /// The counters now, the most frequent row first (then the slowest, then by id).
    ///
    /// - Parameter dropped: Runs the monitor could not hand over (``ActionBudgetMonitor/droppedRunCount``).
    public func snapshot(dropped: Int) -> ActionBudgetCounts {
        let sorted = rows.values.sorted {
            ($0.count, $0.maxMilliseconds, $1.id, $1.entrypoint) > ($1.count, $1.maxMilliseconds, $0.id, $0.entrypoint)
        }
        return ActionBudgetCounts(budgetMilliseconds: budgetMilliseconds, bucketEdgesMilliseconds: Self.bucketEdgesMilliseconds,
                                  runsTotal: total, runsExcluded: excluded, runsDropped: dropped, overBudgetTotal: over, rows: sorted)
    }
}

extension HistogramID.Entrypoint {
    /// The `action.commit` histogram of runs from `entrypoint` (the same cases, by name).
    init(_ entrypoint: ActionEntrypoint) {
        switch entrypoint {
        case .key: self = .key
        case .pointer: self = .pointer
        case .unattributed: self = .unattributed
        case .cli: self = .cli
        case .mcp: self = .mcp
        case .script: self = .script
        case .remote: self = .remote
        case .page: self = .page
        }
    }
}
