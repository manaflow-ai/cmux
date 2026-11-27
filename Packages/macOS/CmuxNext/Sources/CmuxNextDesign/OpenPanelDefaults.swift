/// The prompt and message a panel made ahead had when it was made: a free panel gets them back before it is
/// handed out again, so it comes as a new panel would.
struct OpenPanelDefaults: Sendable {
    var prompt: String
    var message: String

    /// The texts of `panel` as it was made, or nil when it has no prompt: its view service never answered (no
    /// GUI session, 2026-10-23), so the panel is not worth keeping. Never unwraps the texts. Seen on macOS 26 fleet
    /// hosts with no session; that a fresh panel in a working session always has a prompt is not yet checked on
    /// 14, 15 and 27, so ``MadeAheadPanelStore`` logs each drop (category `openPanel`).
    @MainActor init?(of panel: some OpenPanelLabels) {
        guard let prompt = panel.openPanelPrompt else { return nil }
        self.prompt = prompt
        message = panel.openPanelMessage ?? ""
    }

    /// Puts the texts back on `panel`.
    @MainActor func apply(to panel: some OpenPanelLabels) {
        panel.setOpenPanelTexts(prompt: prompt, message: message)
    }
}
