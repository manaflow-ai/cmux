public import CoreGraphics
public import Foundation

/// The sizes of a popover that opens from the sidebar (the update card's What's New highlights) at
/// one density, in points (``SidebarRowTokens/popover``). The native host sizes its window with
/// ``width``; the popover's page reads all of them as `--cmux-sidebar-pop-*` (``cssVariables(pageZoom:)``).
///
/// Every value derives from the rows' tokens (Lawrence msg 19857: "proportional [to] the compactness
/// of [the] ui ... cohesive, and derived"): the text is the rows' title and detail text, the lines are
/// ``lineRatio`` times the text on whole points, the insets are the rows' inset doubled and the card's
/// vertical padding plus a step, and the width is ``widthInBodies`` body sizes. See
/// `docs/cmux-next/derived-sizing.md`.
public nonisolated struct SidebarPopoverMetrics: Equatable, Sendable {
    /// The popover's width: ``widthInBodies`` times ``bodySize``, on the 2 pt grid.
    public var width: CGFloat
    /// Between the popover's edge and its text, left and right.
    public var paddingX: CGFloat
    /// Between the popover's edge and its text, top and bottom.
    public var paddingY: CGFloat
    /// A change's title (the rows' title size) and its line height.
    public var bodySize: CGFloat
    public var bodyLine: CGFloat
    /// A change's second line, the heading and the footer (the rows' detail size) and its line height.
    public var detailSize: CGFloat
    public var detailLine: CGFloat
    /// Above and below each change.
    public var itemPaddingY: CGFloat
    /// The change number's column, and the gap after it.
    public var numberColumn: CGFloat
    public var columnGap: CGFloat
    /// Between the heading, the list and the footer.
    public var blockGap: CGFloat
    /// A change's picture's corner (the rows' corner).
    public var mediaRadius: CGFloat

    /// A popover line's height per point of its text (11/8: 12 pt text on 17 pt lines, 13 on 18).
    public static let lineRatio: CGFloat = 11.0 / 8.0
    /// The width in body sizes: about 50 characters a line at any text size.
    public static let widthInBodies: CGFloat = 26

    public init(width: CGFloat, paddingX: CGFloat, paddingY: CGFloat, bodySize: CGFloat, bodyLine: CGFloat,
                detailSize: CGFloat, detailLine: CGFloat, itemPaddingY: CGFloat, numberColumn: CGFloat,
                columnGap: CGFloat, blockGap: CGFloat, mediaRadius: CGFloat) {
        self.width = width
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.bodySize = bodySize
        self.bodyLine = bodyLine
        self.detailSize = detailSize
        self.detailLine = detailLine
        self.itemPaddingY = itemPaddingY
        self.numberColumn = numberColumn
        self.columnGap = columnGap
        self.blockGap = blockGap
        self.mediaRadius = mediaRadius
    }

    /// A line's height for `size` pt text: ``lineRatio`` times it, on whole points.
    public static func line(for size: CGFloat) -> CGFloat { (size * lineRatio).rounded() }

    /// The CSS variables' names, in the order ``cssVariables(pageZoom:)`` fills them.
    public static let cssKeys = [
        "--cmux-sidebar-pop-width", "--cmux-sidebar-pop-padding-x", "--cmux-sidebar-pop-padding-y",
        "--cmux-sidebar-pop-body", "--cmux-sidebar-pop-body-line", "--cmux-sidebar-pop-detail",
        "--cmux-sidebar-pop-detail-line", "--cmux-sidebar-pop-item-padding-y", "--cmux-sidebar-pop-number",
        "--cmux-sidebar-pop-column-gap", "--cmux-sidebar-pop-block-gap", "--cmux-sidebar-pop-media-radius",
    ]

    /// The sizes in CSS px of a page zoomed by `pageZoom` (a CSS px is `pageZoom` points), so the page
    /// draws the rows' point sizes at any content scale.
    public func cssVariables(pageZoom: CGFloat) -> [String: String] {
        let zoom = max(pageZoom, 0.01)
        let values = [width, paddingX, paddingY, bodySize, bodyLine, detailSize, detailLine, itemPaddingY,
                      numberColumn, columnGap, blockGap, mediaRadius]
        return Dictionary(uniqueKeysWithValues: zip(Self.cssKeys, values.map { SidebarCardMetrics.px($0 / zoom) }))
    }
}
