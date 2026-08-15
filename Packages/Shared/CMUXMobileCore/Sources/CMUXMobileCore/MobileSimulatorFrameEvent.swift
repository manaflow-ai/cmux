public enum MobileSimulatorFrameFormat: String, Codable, Equatable, Sendable {
    case jpeg
    case png
}

public struct MobileSimulatorFrameEvent: Codable, Equatable, Sendable {
    public let panelID: String
    public let sequence: UInt64
    public let format: MobileSimulatorFrameFormat
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let displayScale: Double
    public let dataBase64: String

    public init(
        panelID: String,
        sequence: UInt64,
        format: MobileSimulatorFrameFormat,
        pixelWidth: Int,
        pixelHeight: Int,
        displayScale: Double,
        dataBase64: String
    ) {
        self.panelID = panelID
        self.sequence = sequence
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.displayScale = displayScale
        self.dataBase64 = dataBase64
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case sequence = "seq"
        case format
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case displayScale = "display_scale"
        case dataBase64 = "data_base64"
    }
}
