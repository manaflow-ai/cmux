import Foundation

/// Typed panel selection for browser stream lifecycle and chrome commands.
struct MobileBrowserPanelParameters: Encodable, Sendable {
    /// The Mac browser panel identifier.
    let panelID: String

    /// Creates panel parameters.
    init(panelID: String) { self.panelID = panelID }

    private enum CodingKeys: String, CodingKey { case panelID = "panel_id" }
}
