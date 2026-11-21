import CmuxHomeRender

/// A bubble's ``HomeDiagramStyle`` as Ondine's CSS custom properties.
///
/// Ondine paints with `--ondine-bg`, `--ondine-fg` and friends, each falling
/// back to a mix of the two. Lines and borders are the text colour toned 25%
/// toward the bubble, node fills are clear (the bubble shows through: a sent
/// bubble's fill is a gradient no flat colour matches), and text is Menlo,
/// the monospace face Ondine measures for.
nonisolated struct OndineDiagramColors: Hashable, Sendable {
    /// The bubble's colours.
    var style: HomeDiagramStyle

    /// - Parameter style: the colours of the bubble the diagram sits in.
    init(style: HomeDiagramStyle) {
        self.style = style
    }

    /// Values by custom property name, for ``SVGCustomPropertyResolver``.
    var overrides: [String: String] {
        let bg = Self.hex(style.background), fg = Self.hex(style.foreground)
        let toned = "color-mix(in srgb, \(fg) 75%, \(bg))"
        return [
            "--ondine-bg": bg,
            "--ondine-fg": fg,
            "--ondine-muted": "color-mix(in srgb, \(fg) 65%, \(bg))",
            "--ondine-line": toned,
            "--ondine-border": toned,
            "--ondine-surface": "none",
            "--ondine-accent": Self.hex(style.accent),
            "--ondine-font": "Menlo",
        ]
    }

    private static func hex(_ color: HomeColor) -> String {
        SVGColor(red: Double(color.red), green: Double(color.green), blue: Double(color.blue)).hex
    }
}
