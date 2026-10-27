/// Decides whether a pane may be restarted now to apply a session priority target.
///
/// The restart runs unattended and ends the pane's Claude process, so it waits for Claude to sit
/// at its empty input prompt between turns, in the foreground, with nobody typing and no account
/// switch on the pane. The first failing check names the hold.
struct SessionPriorityApplyGate {
    /// What the pane shows and does right now.
    struct Facts {
        /// Claude reports a turn in progress.
        var responseRunning: Bool
        /// The pane got input within ``SessionPriorityApplyGate/quietInputWindow``.
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
    }

    /// Why the restart waits.
    enum HoldReason: String, Sendable {
        case responding
        case recentInput
        case draft
        case dialog
        case interruptHint
        case notForeground
        case unknownScreen
        case accountSwitchInFlight
        /// Session priority was turned off while the restart was being prepared.
        case disabled
        /// The user changed the effort or model in the pane while it waited for its restart.
        case manualChange
    }

    /// The gate's answer.
    enum Verdict: Equatable, Sendable {
        case proceed
        case hold(HoldReason)
    }

    /// How long the pane must go without input before it may be restarted.
    static let quietInputWindow: Duration = .seconds(10)

    /// Checks, in order: account switch, a manual change on screen, running turn, recent input,
    /// the running-turn hint, the screen (only Claude's empty prompt passes), and the foreground.
    static func evaluate(_ facts: Facts) -> Verdict {
        if facts.accountSwitchInFlight { return .hold(.accountSwitchInFlight) }
        // Restarting now would replace the user's own effort with the target's.
        if facts.screenShowsManualChange { return .hold(.manualChange) }
        if facts.responseRunning { return .hold(.responding) }
        if facts.receivedInputRecently { return .hold(.recentInput) }
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
