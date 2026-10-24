/// What the user needs to finish a Claude account switch whose resume command cmux never typed.
struct ClaudeAccountSwitchManualResume: Equatable, Sendable {
    /// The resume command cmux built, verbatim:
    /// `cd <dir> && env -u <cleared keys> <launcher …> --resume <id>`. It replays the target's
    /// launch environment and unsets the account keys the switch clears, so it resumes on the
    /// target account even where the shell re-exports `CLAUDE_CONFIG_DIR`.
    let command: String
    /// The input cmux would have typed into the respawned shell, ending in a newline. Past
    /// Fork's inline limit it runs ``command`` from a one-shot launcher script.
    let typedInput: String
    /// Whether the respawned pane was closed, moved or respawned again before the resume could
    /// be typed, which leaves no pane to type it into.
    let paneWasReplaced: Bool
}
