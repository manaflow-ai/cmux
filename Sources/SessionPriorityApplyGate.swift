/// Decides whether a pane may be restarted now to apply a session priority target.
///
/// The restart runs unattended and ends the pane's Claude process, so it waits for Claude to sit
/// at its empty input prompt between turns, in the foreground, with no background work, nobody
/// typing or looking at the pane, and no account switch on the pane. The first failing check
/// names the hold.
struct SessionPriorityApplyGate {
    /// What the pane shows and does right now.
    struct Facts {
        /// Claude reports a turn in progress.
        var responseRunning: Bool
        /// The pane is inside its quiet window (``SessionPriorityApplyGate/isInsideQuietWindow(nowMs:receivedInputAfter:lastTurnEndMs:)``).
        var receivedInputRecently: Bool
        /// What the pane's screen shows.
        var screen: ClaudeAccountAutoSwitchContinueGate.Screen
        /// Claude owns the terminal's foreground, not a shell or another program.
        var claudeInForeground: Bool
        /// A Claude account switch of the pane is in progress.
        var accountSwitchInFlight: Bool
        /// The screen shows a `/effort` or `/model` result the user has not dismissed: they chose
        /// the effort themselves while the pane waited for its restart.
        var screenShowsManualChange = false
        /// The workspace was marked "Don't Adjust" while the restart was being prepared.
        var workspaceMarkedManual = false
        /// The queued target is still what the workspace's tier and difficulty ask for.
        var targetIsCurrent = true
        /// Claude ended its last turn with background work still running (background Bash
        /// commands, Monitors, async Agents) and has not started a turn since: the restart would
        /// kill it.
        var backgroundWorkPending = false
        /// The pane is the focused pane of the key window: the user's next keystrokes would land
        /// in the restarted shell.
        var paneIsFocused = false
    }

    /// Why the restart waits.
    enum HoldReason: String, Sendable {
        case responding
        case backgroundWork
        case recentInput
        case focused
        case draft
        case dialog
        case interruptHint
        case notForeground
        case unknownScreen
        case accountSwitchInFlight
        /// Session priority was turned off while the restart was being prepared.
        case disabled
        /// The user changed the effort or model in the pane, or marked the workspace manual,
        /// while it waited for its restart.
        case manualChange
        /// The workspace's target changed while the restart was being prepared.
        case targetChanged
    }

    /// The gate's answer.
    enum Verdict: Equatable, Sendable {
        case proceed
        case hold(HoldReason)
    }

    /// How long the pane must go without input, and since its last turn end, before it may be
    /// restarted.
    static let quietInputWindow: Duration = .seconds(10)

    /// ``quietInputWindow`` in milliseconds.
    static var quietInputWindowMs: Int64 {
        let (seconds, attoseconds) = quietInputWindow.components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }

    /// Whether the pane is still inside its quiet window at `nowMs`, which runs from the later of
    /// its last input and its Claude's last turn end. A long turn's last input was the prompt that
    /// started it, so the turn end opens the window again.
    ///
    /// - Parameter receivedInputAfter: Whether the pane got input later than the given time.
    static func isInsideQuietWindow(
        nowMs: Int64,
        receivedInputAfter: (Int64) -> Bool,
        lastTurnEndMs: Int64?
    ) -> Bool {
        let windowStart = nowMs - quietInputWindowMs
        return (lastTurnEndMs ?? .min) > windowStart || receivedInputAfter(windowStart)
    }

    /// Checks, in order: account switch, a manual change (on screen or the workspace flag), a
    /// changed target, background work, running turn, recent input, the focused pane, the
    /// running-turn hint, the screen (only Claude's empty prompt passes), and the foreground.
    static func evaluate(_ facts: Facts) -> Verdict {
        if facts.accountSwitchInFlight { return .hold(.accountSwitchInFlight) }
        // Restarting now would replace the user's own effort with the target's.
        if facts.screenShowsManualChange || facts.workspaceMarkedManual { return .hold(.manualChange) }
        if !facts.targetIsCurrent { return .hold(.targetChanged) }
        // Ahead of a running turn: a hook after the turn's end (a `SubagentStop`) can report the
        // pane running again while its background work goes on.
        if facts.backgroundWorkPending { return .hold(.backgroundWork) }
        if facts.responseRunning { return .hold(.responding) }
        if facts.receivedInputRecently { return .hold(.recentInput) }
        if facts.paneIsFocused { return .hold(.focused) }
        // Claude keeps its input box empty while it works, so this outranks the screen.
        if facts.screen.showsInterruptHint { return .hold(.interruptHint) }
        switch facts.screen.state {
        case .emptyPrompt:
            break
        case .draft:
            return .hold(.draft)
        case .dialog:
            return .hold(.dialog)
        case .unknown, .codexGoalResume, .codexResumePicker:
            return .hold(.unknownScreen)
        }
        if !facts.claudeInForeground { return .hold(.notForeground) }
        return .proceed
    }
}
