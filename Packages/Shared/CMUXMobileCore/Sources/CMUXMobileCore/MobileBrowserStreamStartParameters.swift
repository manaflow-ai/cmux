/// Parameters for starting a browser stream with an optional phone viewport.
public struct MobileBrowserStreamStartParameters: Codable, Equatable, Sendable {
    /// Mac browser panel identifier.
    public let panelID: String
    /// Phone viewport to apply before capture, when the Mac supports reflow.
    public let viewport: MobileBrowserViewport?

    /// Creates browser stream start parameters.
    /// - Parameters:
    ///   - panelID: Mac browser panel identifier.
    ///   - viewport: Phone viewport to apply before capture.
    public init(panelID: String, viewport: MobileBrowserViewport? = nil) {
        self.panelID = panelID
        self.viewport = viewport
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panelID = try container.decode(String.self, forKey: .panelID)
        let hasViewport = container.contains(.viewportWidth)
            || container.contains(.viewportHeight)
            || container.contains(.viewportScale)
        if hasViewport {
            viewport = MobileBrowserViewport(
                width: try container.decode(Int.self, forKey: .viewportWidth),
                height: try container.decode(Int.self, forKey: .viewportHeight),
                scale: try container.decode(Double.self, forKey: .viewportScale)
            )
        } else {
            viewport = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(panelID, forKey: .panelID)
        if let viewport {
            try container.encode(viewport.width, forKey: .viewportWidth)
            try container.encode(viewport.height, forKey: .viewportHeight)
            try container.encode(viewport.scale, forKey: .viewportScale)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case viewportWidth = "viewport_width"
        case viewportHeight = "viewport_height"
        case viewportScale = "viewport_scale"
    }
}
