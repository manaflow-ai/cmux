import Foundation

/// Parameters for `mobile.browser.input.text`.
public struct MobileBrowserTextInput: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Text to insert into the focused page element.
    public let text: String

    /// Creates text input parameters.
    public init(panelID: String, text: String) {
        self.panelID = panelID
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case text
    }
}
