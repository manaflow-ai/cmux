/// The forms of one icon: Line, Solid and an optional Cat variant of Line.
public nonisolated struct IconDrawing: Hashable, Sendable, Decodable {
    public var line: [IconLayer]
    public var solid: [IconLayer]
    public var cat: [IconLayer]?

    public init(line: [IconLayer], solid: [IconLayer], cat: [IconLayer]? = nil) {
        self.line = line
        self.solid = solid
        self.cat = cat
    }

    /// The layers for `style`. The Cat drawing replaces Line only; Solid
    /// (selected) stays Solid whatever the accent.
    public func layers(style: IconStyle, accent: IconAccent) -> [IconLayer] {
        if style == .line, accent == .cat, let cat {
            return cat
        }
        return style == .solid ? solid : line
    }
}
