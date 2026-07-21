/// A page-runtime request to turn one completed freehand stroke into a snapshot card.
public struct BrowserDesignModeAnnotationCaptureRequest: Codable, Equatable, Sendable {
    /// Stable identity for the stroke and its eventual context selection.
    public let id: String
    /// The stroke bounds in CSS viewport points at the reported scroll position.
    public let strokeBounds: BrowserDesignModeRect
    /// The viewport associated with ``strokeBounds``.
    public let viewport: BrowserDesignModeViewport
    /// Horizontal page scroll in CSS points when the descriptor was produced.
    public let scrollX: Double
    /// Vertical page scroll in CSS points when the descriptor was produced.
    public let scrollY: Double

    private enum CodingKeys: String, CodingKey {
        case id
        case strokeBounds = "stroke_bounds"
        case viewport
        case scrollX = "scroll_x"
        case scrollY = "scroll_y"
    }

    /// Creates an annotation capture request.
    /// - Parameters:
    ///   - id: Stable stroke identity.
    ///   - strokeBounds: Stroke bounds in CSS viewport points.
    ///   - viewport: Visible page viewport.
    ///   - scrollX: Horizontal page scroll.
    ///   - scrollY: Vertical page scroll.
    public init(
        id: String,
        strokeBounds: BrowserDesignModeRect,
        viewport: BrowserDesignModeViewport,
        scrollX: Double,
        scrollY: Double
    ) {
        self.id = id
        self.strokeBounds = strokeBounds
        self.viewport = viewport
        self.scrollX = scrollX
        self.scrollY = scrollY
    }
}
