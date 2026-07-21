import Foundation

/// Typed parameters for `mobile.browser.navigate`.
struct MobileBrowserNavigateParameters: Encodable, Sendable {
    /// The Mac browser panel identifier.
    let panelID: String
    /// The address interpreted by the Mac browser's smart navigation.
    let url: String

    /// Creates navigation parameters.
    init(panelID: String, url: String) {
        self.panelID = panelID
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case panelID = "panel_id"; case url }
}
