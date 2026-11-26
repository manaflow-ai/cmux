import Foundation

/// Payload pushed on the `browser.frame` topic.
public struct MobileBrowserFrameEvent: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Monotonic sequence within this subscription.
    public let sequence: UInt64
    /// Image encoding used by this frame.
    public let format: MobileBrowserFrameFormat
    /// Visible page width in points.
    public let pageWidth: Double
    /// Visible page height in points.
    public let pageHeight: Double
    /// Encoded bitmap width in pixels.
    public let pixelWidth: Int
    /// Encoded bitmap height in pixels.
    public let pixelHeight: Int
    /// Base64-encoded image bytes.
    public let dataBase64: String

    /// Creates a browser frame event.
    public init(
        panelID: String,
        sequence: UInt64,
        format: MobileBrowserFrameFormat,
        pageWidth: Double,
        pageHeight: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        dataBase64: String
    ) {
        self.panelID = panelID
        self.sequence = sequence
        self.format = format
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dataBase64 = dataBase64
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case sequence = "seq"
        case format
        case pageWidth = "page_width"
        case pageHeight = "page_height"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case dataBase64 = "data_b64"
    }
}
