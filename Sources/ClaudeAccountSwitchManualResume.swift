/// What the user needs to finish a Claude account switch whose resume command cmux never typed.
struct ClaudeAccountSwitchManualResume: Equatable, Sendable {
    /// Why cmux left the resume to the user.
    enum Reason: Equatable, Sendable {
        /// The respawned pane was closed, moved or respawned again before the resume could be
        /// typed, which leaves no pane to type it into.
        case paneReplaced
        /// The respawned shell reported no prompt in time, or the terminal refused the input.
        case notTyped
        /// The replaced Claude, with these process ids, was still running after the switch waited
        /// for it to exit. Resuming now would run the session in two places, so the user runs the
        /// command once it has quit.
        case previousClaudeStillRunning(processIDs: [Int32])
    }

    /// The resume command cmux built, verbatim:
    /// `cd <dir> && env -u <cleared keys> <launcher …> --resume <id>`. It replays the target's
    /// launch environment and unsets the account keys the switch clears, so it resumes on the
    /// target account even where the shell re-exports `CLAUDE_CONFIG_DIR`.
    let command: String
    /// The input cmux would have typed into the respawned shell, ending in a newline. Past
    /// Fork's inline limit it runs ``command`` from a one-shot launcher script.
    let typedInput: String
    /// Why the resume was not typed.
    let reason: Reason

    init(command: String, typedInput: String, reason: Reason) {
        self.command = command
        self.typedInput = typedInput
        self.reason = reason
    }

    /// A resume the pane never received: `paneWasReplaced` picks ``Reason/paneReplaced`` over
    /// ``Reason/notTyped``.
    init(command: String, typedInput: String, paneWasReplaced: Bool) {
        self.init(command: command, typedInput: typedInput, reason: paneWasReplaced ? .paneReplaced : .notTyped)
    }

    /// Whether the respawned pane is gone, so there is nothing to type the resume into.
    var paneWasReplaced: Bool { reason == .paneReplaced }
}
