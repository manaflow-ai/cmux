public import CoreGraphics

/// The column widths Equalize Splits gives a columns screen (Lawrence 2026-11-05: "cmd ctrl = fails to equalize home
/// imessage/chief and the stuff on the right"): every column a person sees side by side gets the same width on screen.
///
/// - A docked left or right dock (Home's Chief chat) counts as one of those columns. Its width is a share of the whole
///   window and the strip's columns share what it leaves, so its fraction is solved from the pixel width all columns
///   get: `W = (viewport - (docks + strip columns + 1) * gap) / (docks + strip columns)`. It never goes below its panes'
///   minimum width (the chat's) or above the share a dock may take (`DockStripGeometry`); then the strip columns still
///   share the rest equally.
/// - The strip's columns each get `1 / n` of the strip: `n` is every strip column when all of them fit beside the docks
///   at their minimum width, so they all share the window; else the strip columns the window shows (any part of them),
///   so those fill it, and the ones scrolled out get the same width.
/// - An overlay dock floats over the strip and a top or bottom dock is a band: neither shares the width, both keep it.
///   A dock alone on its screen fills it (`pinned-dock-alone-v1`) and keeps its width.
///
/// ```swift
/// let resizes = ColumnEqualizer(columns: columns, visible: ["c1"], viewportWidth: 1440, gap: 8) {
///     $0.minimumSize(style: style).width
/// }.resizes
/// ```
public nonisolated struct ColumnEqualizer {
    /// The screen's columns, in daemon order.
    public var columns: [LayoutColumn]
    /// The strip columns the window shows now (any part of them); empty when unknown.
    public var visible: Set<ColumnID>
    /// The screen's viewport width in points.
    public var viewportWidth: CGFloat
    /// The strip gap (`LayoutStyle.stripGap`).
    public var gap: CGFloat
    /// A column's minimum width in points (`LayoutColumn.minimumSize(style:)`).
    public var minimumWidth: (LayoutColumn) -> CGFloat

    /// - Parameters:
    ///   - columns: The screen's columns.
    ///   - visible: The strip columns in view; empty counts every strip column.
    ///   - viewportWidth: The screen's width in points.
    ///   - gap: The strip gap in points.
    ///   - minimumWidth: Each column's minimum width in points.
    public init(columns: [LayoutColumn], visible: Set<ColumnID> = [], viewportWidth: CGFloat, gap: CGFloat,
                minimumWidth: @escaping (LayoutColumn) -> CGFloat) {
        self.columns = columns
        self.visible = visible
        self.viewportWidth = viewportWidth
        self.gap = gap
        self.minimumWidth = minimumWidth
    }

    /// The widths that differ from the ones the columns have; empty when they are equal already. Run by
    /// cmux-layout-reducer (`layout_model_equalize_columns`; `schemas/layout-model/vectors.json`).
    public var resizes: [ColumnResize] {
        struct Request: Encodable {
            var columns: [LayoutColumn], visible: Set<ColumnID>, viewportWidth: Double, gap: Double
            var minimumWidths: [String: Double]
        }
        struct Reply: Decodable { var resizes: [ColumnResize] }
        let widths = Dictionary(columns.map { ($0.id.rawValue, Double(minimumWidth($0))) }) { first, _ in first }
        let request = Request(columns: columns, visible: visible, viewportWidth: Double(viewportWidth), gap: Double(gap),
                              minimumWidths: widths)
        let reply: Reply? = LayoutRules.call("layout_model_equalize_columns", request)
        return reply?.resizes ?? []
    }
}
