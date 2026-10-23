/// The prompt and message a panel made ahead had when it was made: a free panel gets them back before it is
/// handed out again, so it comes as a new panel would.
struct OpenPanelDefaults: Sendable {
    var prompt: String
    var message: String

    /// The texts of `panel` as it was made.
    @MainActor init(of panel: some OpenPanelLabels) {
        prompt = panel.openPanelPrompt ?? ""
        message = panel.openPanelMessage ?? ""
    }

    /// Puts the texts back on `panel`.
    @MainActor func apply(to panel: some OpenPanelLabels) {
        panel.setOpenPanelTexts(prompt: prompt, message: message)
    }
}
