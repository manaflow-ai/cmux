import AppKit
import CmuxNextCopyMode

/// The cmux layer that draws a terminal's echo predictions over its Ghostty surface,
/// as mosh's overlay does: each predicted glyph dim and underlined on the terminal background, a
/// predicted blank (a backspace) as background only, and a bar where typing continues. Not Ghostty's
/// preedit, which draws at the cursor and cannot show a backspace over a cell.
///
/// A subview of the surface view, like the copy-mode cursor box, sized to the cells it draws and
/// hidden when there is nothing to draw, so an idle terminal has no layer over its renderer. It takes
/// no mouse events. It changes in the turn that changed the predictions, with no animation.
final class PredictiveEchoOverlay: NSView {
    /// How the cells draw: the terminal's font and colors, and where its cells are in the view.
    struct Style: Equatable {
        /// Ghostty's terminal face (`ghostty_surface_quicklook_font`).
        var font: CTFont
        var foreground: NSColor
        var background: NSColor
        var cursor: NSColor
        var cells: CopyModeCursorFrame

        static func == (lhs: Style, rhs: Style) -> Bool {
            CFEqual(lhs.font, rhs.font) && lhs.foreground == rhs.foreground && lhs.background == rhs.background
                && lhs.cursor == rhs.cursor && lhs.cells == rhs.cells
        }
    }

    /// The terminal colors a ``Style`` draws with.
    struct Colors: Equatable {
        var foreground: NSColor
        var background: NSColor
        var cursor: NSColor
    }

    /// The overlay's colors for a terminal with `theme` and, when the program set one (OSC 11),
    /// `backgroundOverride`. Nil on a translucent background: each cell's opaque fill would show as a
    /// block over the window behind it, and a translucent fill could not hide the glyph under a
    /// predicted blank.
    static func colors(of theme: GhosttyThemeColors, backgroundOverride: NSColor?) -> Colors? {
        guard theme.backgroundOpacity >= 1 else { return nil }
        let foreground = color(theme.foreground)
        return Colors(foreground: foreground, background: backgroundOverride ?? color(theme.background),
                      cursor: theme.cursor.map { color($0) } ?? foreground)
    }

    private static func color(_ rgb: GhosttyThemeColors.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    /// The predicted glyphs' share of the foreground: dim, as mosh draws unconfirmed text.
    static let glyphAlpha: CGFloat = 0.6
    static let cursorWidth: CGFloat = 2

    private(set) var cells: [PredictiveEcho.Cell] = []
    private(set) var cursor: PredictiveEcho.Position?
    private(set) var style: Style?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Mouse events belong to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Draws `cells` and `cursor` with `style`, or hides when there is nothing to draw.
    func show(_ cells: [PredictiveEcho.Cell], cursor: PredictiveEcho.Position?, style: Style?) {
        guard let style, let area = Self.area(of: cells, cursor: cursor, style: style) else {
            self.cells = []
            self.cursor = nil
            isHidden = true
            return
        }
        // The slot shows the predictions again on each echo and frame; the same cells paint nothing.
        let changed = isHidden || cells != self.cells || cursor != self.cursor || style != self.style
        (self.cells, self.cursor, self.style) = (cells, cursor, style)
        if frame != area { frame = area }
        if changed { needsDisplay = true } // invalidate: other cells, cursor or style (`changed`)
        isHidden = false
    }

    /// The rectangle covering every cell and the cursor, in the surface view's coordinates.
    static func area(of cells: [PredictiveEcho.Cell], cursor: PredictiveEcho.Position?, style: Style) -> NSRect? {
        var rects = cells.map { style.cells.rect(column: $0.column, row: $0.row, widthCells: 1) }
        if let cursor { rects.append(style.cells.rect(column: cursor.column, row: cursor.row, widthCells: 1)) }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        let origin = frame.origin
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: style.foreground.withAlphaComponent(Self.glyphAlpha),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        for cell in cells {
            let rect = style.cells.rect(column: cell.column, row: cell.row, widthCells: 1).offsetBy(dx: -origin.x, dy: -origin.y)
            style.background.setFill()
            rect.fill()
            guard cell.glyph != PredictiveEcho.blank else { continue }
            let text = String(decoding: [cell.glyph], as: UTF8.self) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.minX + max(0, (rect.width - size.width) / 2),
                                  y: rect.minY + max(0, (rect.height - size.height) / 2)),
                      withAttributes: attributes)
        }
        if let cursor {
            let rect = style.cells.rect(column: cursor.column, row: cursor.row, widthCells: 1).offsetBy(dx: -origin.x, dy: -origin.y)
            style.cursor.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: min(Self.cursorWidth, rect.width), height: rect.height).fill()
        }
    }
}
