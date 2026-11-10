import CmuxNextWakeups

/// After a terminal is shown again, checks once, ``limit`` later, whether its pane still shows nothing
/// (the Nov 4 report: a shown pane stayed empty for minutes while its terminals ran), or shows frames at
/// another scale than Ghostty draws at (the same report's tiny text). A pane that drew at its scale,
/// or was hidden again meanwhile (``cancel()``), reports nothing. One check per reveal; a new reveal
/// replaces the pending one.
@MainActor
final class TerminalBlankWatch {
    /// How long a shown terminal may show nothing before it is reported: past the frame hold's limit
    /// (``TerminalFrameHold/limit``) and many display refreshes, so only a real blank counts.
    static let limit: Duration = .milliseconds(500)

    private let timer: DemandTimer

    /// - Parameter clock: The deadline's clock; tests pass a manual clock.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = DemandTimer(owner: "TerminalBlankWatch.limit", clock: clock)
    }

    /// Whether a check waits.
    var isWatching: Bool { timer.isScheduled }

    /// Checks `probe` after ``limit``: `onBlank` gets its report when it says the pane is still blank;
    /// `onScaleMismatch` gets it when the pane drew and its scales still disagree
    /// (``TerminalRevealReport/scalesAgree``: at the reveal itself a layer scale that waits for its first frame
    /// is no mismatch, so this check is the one that sees a scale that never landed). `probe` returns nil once
    /// the terminal is no longer shown (nothing to report).
    func watch(probe: @escaping @MainActor @Sendable () -> TerminalRevealReport?,
               onBlank: @escaping @MainActor @Sendable (TerminalRevealReport) -> Void,
               onScaleMismatch: @escaping @MainActor @Sendable (TerminalRevealReport) -> Void = { _ in }) {
        timer.schedule(after: Self.limit) { @MainActor in
            guard let report = probe() else { return }
            if report.isBlank {
                onBlank(report)
            } else if !report.scalesAgree {
                onScaleMismatch(report)
            }
        }
    }

    /// The terminal was hidden or closed: no check.
    func cancel() { timer.cancel() }
}
