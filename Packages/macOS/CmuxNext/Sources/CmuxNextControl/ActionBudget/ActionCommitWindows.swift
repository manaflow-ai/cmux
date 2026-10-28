public import CmuxNextActions
public import CmuxNextMetrics
public import CmuxNextWakeups

/// The frames right after the person's actions (p09-observability task 056, over task 057's frame sequences): each
/// committed key or pointer run opens, or extends, a commit window on the scheduler of the window the person acts in
/// (`FrameScheduler.noteCommit()`), and a window that a New Tab, New Window or Close Tab key run opened or last
/// extended records its missed refreshes as `action.missed_frames.<command>` when it closes. Chrome reads the
/// dropped frames of an interaction from the frame sequence its input started the same way
/// (cc/metrics/frame_sequence_tracker_collection.cc).
///
/// The window takes its command on main at the command's commit, so no window is matched to a run by time and none
/// waits for the runs' off-main batches. A window that ends with no frame to count (its scheduler left its display
/// or went away first) reports nothing, and its command records no sample. Scripted, agent and socket runs open no
/// window: the windows measure what the person sees after their own input.
///
/// ```swift
/// let windows = ActionCommitWindows(monitor: services.actionBudget) { NSApp.keyWindow.map(FrameScheduler.forWindow) }
/// ```
@MainActor
public final class ActionCommitWindows {
    private let metrics: Metrics
    private let scheduler: @MainActor () -> FrameScheduler?
    /// The timed commands by the monitor's interned action index.
    private let commands: [UInt32: HistogramID.Command]
    /// The schedulers that opened a window, by identity (an entry whose scheduler went away is dropped when the next
    /// new scheduler comes).
    private var owners: [ObjectIdentifier: Owner] = [:]

    /// One scheduler's commit window: the timed command it records for, nil for none.
    private final class Owner {
        weak var scheduler: FrameScheduler?
        var command: HistogramID.Command?

        init(_ scheduler: FrameScheduler) {
            self.scheduler = scheduler
        }
    }

    /// Takes `monitor`'s ``ActionBudgetMonitor/onCommit``.
    ///
    /// - Parameters:
    ///   - monitor: The per-action budget whose committed runs open the windows.
    ///   - metrics: Where `action.missed_frames` goes (the app's metrics file by default; tests pass their own).
    ///   - scheduler: The scheduler of the window the person acts in (the key window's), or nil for none.
    public init(monitor: ActionBudgetMonitor, metrics: Metrics = Metrics(), scheduler: @escaping @MainActor () -> FrameScheduler?) {
        self.metrics = metrics
        self.scheduler = scheduler
        var commands: [UInt32: HistogramID.Command] = [:]
        for command in HistogramID.Command.allCases {
            commands[monitor.intern(ActionBudgetLedger.actionID(of: command))] = command
        }
        self.commands = commands
        monitor.onCommit = { [weak self] index, entrypoint in self?.runCommitted(index, entrypoint) }
    }

    /// The run of interned action `index` from `entrypoint` committed: a key or pointer run opens or extends a commit
    /// window, and a timed command's key run takes it (a later command in an open window takes it from an earlier
    /// one, as the window counts the frames after both once).
    func runCommitted(_ index: UInt32, _ entrypoint: ActionEntrypoint) {
        guard entrypoint == .key || entrypoint == .pointer, let scheduler = scheduler() else { return }
        let owner = owner(of: scheduler)
        // The last window closed with no frame to count, so it reported nothing: its command leaves with it.
        if !scheduler.sequences.isCommitWindowOpen { owner.command = nil }
        if entrypoint == .key, let command = commands[index] { owner.command = command }
        scheduler.noteCommit()
    }

    /// `scheduler`'s entry, made, with its window reports, the first time it opens a window.
    private func owner(of scheduler: FrameScheduler) -> Owner {
        let key = ObjectIdentifier(scheduler)
        if let owner = owners[key], owner.scheduler === scheduler { return owner }
        owners = owners.filter { $0.value.scheduler != nil }
        let owner = Owner(scheduler)
        owners[key] = owner
        scheduler.sequences.onSequenceEnd = { [weak self, weak owner] kind, report in
            guard kind == .commitWindow, let self, let owner else { return }
            windowClosed(owner, dropped: report.dropped)
        }
        return owner
    }

    private func windowClosed(_ owner: Owner, dropped: UInt32) {
        guard let command = owner.command else { return }
        owner.command = nil
        metrics.record(.actionMissedFrames(command), Int64(clamping: dropped))
    }
}
