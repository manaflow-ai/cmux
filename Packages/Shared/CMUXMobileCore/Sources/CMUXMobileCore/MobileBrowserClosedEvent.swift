import Foundation

/// Payload pushed on the `browser.closed` topic.
public struct MobileBrowserClosedEvent: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String

    /// Creates a browser closed event.
    public init(panelID: String) {
        self.panelID = panelID
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
    }
}
