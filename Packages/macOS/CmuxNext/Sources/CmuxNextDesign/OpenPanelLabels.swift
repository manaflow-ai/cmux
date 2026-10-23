import AppKit

/// The two texts a reused open panel gets back: `NSSavePanel`'s prompt and message, read as optionals (AppKit
/// types them `String!`; both are nil when the panel's view service never answered), so ``OpenPanelDefaults``
/// can be tested without that service.
@MainActor
protocol OpenPanelLabels: AnyObject {
    /// The default button's text, nil when the panel never loaded its view.
    var openPanelPrompt: String? { get }
    /// The text above the browser, nil when the panel never loaded its view.
    var openPanelMessage: String? { get }
    /// Sets both texts.
    func setOpenPanelTexts(prompt: String, message: String)
}

extension NSSavePanel: OpenPanelLabels {
    var openPanelPrompt: String? { prompt }
    var openPanelMessage: String? { message }
    func setOpenPanelTexts(prompt: String, message: String) {
        self.prompt = prompt
        self.message = message
    }
}
