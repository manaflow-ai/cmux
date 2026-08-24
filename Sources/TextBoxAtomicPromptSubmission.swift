import CmuxTerminal

/// One simple TextBox paste-and-submit pair collapsed into the compound
/// terminal primitive on the concrete surface that can honor it.
struct TextBoxAtomicPromptSubmission {
    let text: String
    let submitKey: String
    let rejectIfHumanComposerBusy: Bool
    let hookRecordingSource: String?
    let hookConfirmsHumanInput: Bool
    let surface: TerminalSurface
}
