import Foundation

/// Parameters for `mobile.browser.input.key`.
public struct MobileBrowserKeyInput: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Shortcut-key vocabulary token such as `return`, `up`, or `a`.
    public let key: String
    /// Modifier tokens such as `command`, `control`, `option`, and `shift`.
    public let modifiers: [String]

    /// Creates key input parameters.
    public init(panelID: String, key: String, modifiers: [String]) {
        self.panelID = panelID
        self.key = key
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case key, modifiers
    }
}
