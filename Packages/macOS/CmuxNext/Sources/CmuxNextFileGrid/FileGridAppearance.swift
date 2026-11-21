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
    /// The grid's and each tile's corner radius: the app passes the one corner radius.
    public var cornerRadius: CGFloat
    /// The concentric radius of a shape `inset` points inside a shape of radius `outer`, at most half
    /// the shorter side of `size` when given (the thumbnail in its tile, the badge in its thumbnail).
    /// The app passes the one corner rule, `Metrics.cornerRadius(nestedIn:inset:size:)`; the grid owns no theme.
    public var nestedCornerRadius: @MainActor (_ outer: CGFloat, _ inset: CGFloat, _ size: CGSize?) -> CGFloat

    /// Makes an appearance.
    ///
    /// - Parameters:
    ///   - text: tile name color.
    ///   - secondaryText: durations and notices.
    ///   - selection: selected tile backing.
    ///   - dropHighlight: the drop outline.
    ///   - tileFill: behind a letterboxed thumbnail.
    ///   - tileSide: tile side in points (default 148).
    ///   - cornerRadius: the grid's and a tile's corner (the app passes `Metrics.surfaceCornerRadius`).
    ///   - nestedCornerRadius: the concentric rule (the app passes `Metrics.cornerRadius(nestedIn:inset:size:)`);
    ///     the default is the same rule, outer less inset, for hosts with no design module.
    public init(text: NSColor = .labelColor, secondaryText: NSColor = .secondaryLabelColor,
                selection: NSColor = .unemphasizedSelectedContentBackgroundColor, dropHighlight: NSColor = .tertiaryLabelColor,
                tileFill: NSColor = .quaternaryLabelColor, tileSide: CGFloat = 148,
                cornerRadius: CGFloat = 8,
                nestedCornerRadius: @escaping @MainActor (_ outer: CGFloat, _ inset: CGFloat, _ size: CGSize?) -> CGFloat = { outer, inset, size in
                    let radius = max(0, outer - inset)
                    return size.map { min(radius, min($0.width, $0.height) / 2) } ?? radius
                }) {
        self.text = text
        self.secondaryText = secondaryText
        self.selection = selection
        self.dropHighlight = dropHighlight
        self.tileFill = tileFill
        self.tileSide = tileSide
        self.cornerRadius = cornerRadius
        self.nestedCornerRadius = nestedCornerRadius
    }
}
