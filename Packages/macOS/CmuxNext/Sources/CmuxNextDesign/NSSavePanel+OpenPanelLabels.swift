import AppKit

/// AppKit's panel texts, read as optionals (``OpenPanelLabels``).
extension NSSavePanel: OpenPanelLabels {
    var openPanelPrompt: String? { prompt }
    var openPanelMessage: String? { message }
    func setOpenPanelTexts(prompt: String, message: String) {
        self.prompt = prompt
        self.message = message
    }
}
