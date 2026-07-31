import CmuxTerminalCore

/// One simple TextBox paste-and-submit pair collapsed into the compound
/// terminal primitive at execution time.
struct TextBoxAtomicPromptSubmission {
    let text: String
    let submitKey: String
    let rejectIfHumanComposerBusy: Bool
    let hookRecording: ProgrammaticPromptHookRecording?
}
