import Foundation

/// Parameters for `mobile.browser.input.scroll`.
public struct MobileBrowserScrollInput: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Horizontal scroll delta in points.
    public let deltaX: Double
    /// Vertical scroll delta in points.
    public let deltaY: Double
    /// Native gesture phase.
    public let phase: MobileBrowserScrollPhase
    /// Horizontal page anchor point.
    public let x: Double
    /// Vertical page anchor point.
    public let y: Double

    /// Creates scroll input parameters.
    public init(panelID: String, deltaX: Double, deltaY: Double, phase: MobileBrowserScrollPhase, x: Double, y: Double) {
        self.panelID = panelID
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.phase = phase
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case deltaX = "dx"
        case deltaY = "dy"
        case phase, x, y
    }
}
