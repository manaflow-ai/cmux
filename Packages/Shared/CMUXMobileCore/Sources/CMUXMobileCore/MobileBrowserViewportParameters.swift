/// Parameters for updating an active browser stream's phone viewport.
public struct MobileBrowserViewportParameters: Codable, Equatable, Sendable {
    /// Mac browser panel identifier.
    public let panelID: String
    /// Phone viewport to apply to the streamed panel.
    public let viewport: MobileBrowserViewport

    /// Creates browser viewport update parameters.
    /// - Parameters:
    ///   - panelID: Mac browser panel identifier.
    ///   - viewport: Phone viewport to apply to the streamed panel.
    public init(panelID: String, viewport: MobileBrowserViewport) {
        self.panelID = panelID
        self.viewport = viewport
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panelID = try container.decode(String.self, forKey: .panelID)
        viewport = MobileBrowserViewport(
            width: try container.decode(Int.self, forKey: .viewportWidth),
            height: try container.decode(Int.self, forKey: .viewportHeight),
            scale: try container.decode(Double.self, forKey: .viewportScale)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(panelID, forKey: .panelID)
        try container.encode(viewport.width, forKey: .viewportWidth)
        try container.encode(viewport.height, forKey: .viewportHeight)
        try container.encode(viewport.scale, forKey: .viewportScale)
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case viewportWidth = "viewport_width"
        case viewportHeight = "viewport_height"
        case viewportScale = "viewport_scale"
    }
}
