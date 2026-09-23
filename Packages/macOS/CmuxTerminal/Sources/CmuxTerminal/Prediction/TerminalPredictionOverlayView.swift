public import AppKit
public import CmuxTerminalPrediction

/// Draws the characters cmux is predicting, over the terminal surface.
///
/// The view is sized to exactly the run it is drawing and hidden when there is
/// nothing to draw, so an idle terminal carries no transparent layer over its
/// renderer. It never takes mouse events.
public final class TerminalPredictionOverlayView: NSView {
    /// Each predicted cell paints its own background first. Ghostty is still
    /// drawing a cursor block at the first predicted cell -- it has not seen
    /// these characters -- so painting over it is what makes the cursor look
    /// like it advanced.
    public struct Style: Equatable {
        public var font: NSFont
        public var foreground: NSColor
        public var background: NSColor
        public var cursor: NSColor
        public var cellSize: CGSize

        public init(
            font: NSFont,
            foreground: NSColor,
            background: NSColor,
            cursor: NSColor,
            cellSize: CGSize
        ) {
            self.font = font
            self.foreground = foreground
            self.background = background
            self.cursor = cursor
            self.cellSize = cellSize
        }
    }

    public var style: Style? {
        didSet { if style != oldValue { needsDisplay = true } }
    }

    public var glyphs: [PredictedGlyph] = [] {
        didSet { needsDisplay = true }
    }

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Mouse events belong to the terminal underneath; this is decoration.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        guard let style, !glyphs.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: style.foreground,
            // Underlining unconfirmed text is the convention mosh established,
            // and it is the only cue that separates a guess from the truth.
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        for (index, glyph) in glyphs.enumerated() {
            let cell = CGRect(
                x: CGFloat(index) * style.cellSize.width,
                y: 0,
                width: style.cellSize.width,
                height: style.cellSize.height
            )
            guard cell.maxX <= bounds.width else { break }

            style.background.setFill()
            cell.fill()

            let text = String(glyph.character) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(
                    x: cell.minX + max(0, (cell.width - size.width) / 2),
                    y: cell.minY + max(0, (cell.height - size.height) / 2)
                ),
                withAttributes: attributes
            )
        }

        // A caret where typing continues, because ghostty's own cursor is still
        // painted under the first predicted cell.
        let caret = CGRect(
            x: CGFloat(glyphs.count) * style.cellSize.width,
            y: 0,
            width: 1,
            height: style.cellSize.height
        )
        if caret.maxX <= bounds.width {
            style.cursor.setFill()
            caret.fill()
        }
    }

    /// Positions the run and shows or hides it in one step.
    ///
    /// - Parameters:
    ///   - glyphs: What to draw, left to right from the cursor.
    ///   - cursorOrigin: The cursor cell's frame origin (bottom-left) in the
    ///     host view's coordinates, already converted out of ghostty's
    ///     top-left space.
    public func present(
        glyphs: [PredictedGlyph],
        style: Style,
        cursorOrigin: CGPoint
    ) {
        guard !glyphs.isEmpty else {
            self.glyphs = []
            isHidden = true
            return
        }
        self.style = style
        self.glyphs = glyphs
        // One extra cell of width so the caret after the run has somewhere to
        // land.
        frame = CGRect(
            x: cursorOrigin.x,
            y: cursorOrigin.y,
            width: CGFloat(glyphs.count + 1) * style.cellSize.width,
            height: style.cellSize.height
        )
        isHidden = false
    }
}
