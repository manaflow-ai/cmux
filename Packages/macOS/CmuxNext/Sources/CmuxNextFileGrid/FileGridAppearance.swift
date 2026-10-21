public import AppKit

/// The colors and sizes a ``FileGridView`` draws with. The grid owns no
/// theme: the app passes its palette in (cmux's Ghostty-derived colors), so
/// the core stays free of the design module.
public struct FileGridAppearance {
    /// Tile names.
    public var text: NSColor
    /// Durations, counts and the empty notice.
    public var secondaryText: NSColor
    /// A selected tile's backing.
    public var selection: NSColor
    /// The drop target outline while files are dragged in.
    public var dropHighlight: NSColor
    /// The fill behind a thumbnail that does not cover its tile.
    public var tileFill: NSColor
    /// A tile's side in points (the picture square; the name sits below).
    public var tileSide: CGFloat

    /// Makes an appearance.
    ///
    /// - Parameters:
    ///   - text: tile name color.
    ///   - secondaryText: durations and notices.
    ///   - selection: selected tile backing.
    ///   - dropHighlight: the drop outline.
    ///   - tileFill: behind a letterboxed thumbnail.
    ///   - tileSide: tile side in points (default 148).
    public init(text: NSColor = .labelColor, secondaryText: NSColor = .secondaryLabelColor,
                selection: NSColor = .unemphasizedSelectedContentBackgroundColor, dropHighlight: NSColor = .tertiaryLabelColor,
                tileFill: NSColor = .quaternaryLabelColor, tileSide: CGFloat = 148) {
        self.text = text
        self.secondaryText = secondaryText
        self.selection = selection
        self.dropHighlight = dropHighlight
        self.tileFill = tileFill
        self.tileSide = tileSide
    }
}
