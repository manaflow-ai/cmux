/// The colours a diagram is drawn in: those of the bubble it sits in.
///
/// Conformers of ``HomeDiagramRendering`` derive every diagram colour
/// (lines, borders, node fills, notes) from these three, so a diagram reads
/// like the text of its bubble in light and dark appearances.
public struct HomeDiagramStyle: Hashable, Sendable {
    /// The bubble's fill: the diagram's background and the base of its mixed tints.
    public var background: HomeColor
    /// The bubble's text colour: labels, lines and borders.
    public var foreground: HomeColor
    /// Highlights (for example a Gantt chart's markers): the bubble's link colour.
    public var accent: HomeColor

    /// - Parameters:
    ///   - background: the bubble's fill.
    ///   - foreground: the bubble's text colour.
    ///   - accent: the bubble's link colour.
    public init(background: HomeColor, foreground: HomeColor, accent: HomeColor) {
        self.background = background
        self.foreground = foreground
        self.accent = accent
    }
}
