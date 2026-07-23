import Foundation

/// Parameters for `mobile.browser.input.pointer`.
public struct MobileBrowserPointerInput: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Pointer action.
    public let kind: MobileBrowserPointerKind
    /// Horizontal page point.
    public let x: Double
    /// Vertical page point.
    public let y: Double
    /// AppKit click count.
    public let clickCount: Int
    /// Mouse button.
    public let button: MobileBrowserPointerButton

    /// Creates pointer input parameters.
    public init(
        panelID: String,
        kind: MobileBrowserPointerKind,
        x: Double,
        y: Double,
        clickCount: Int,
        button: MobileBrowserPointerButton
    ) {
        self.panelID = panelID
        self.kind = kind
        self.x = x
        self.y = y
        self.clickCount = clickCount
        self.button = button
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case kind, x, y
        case clickCount = "click_count"
        case button
    }
}
