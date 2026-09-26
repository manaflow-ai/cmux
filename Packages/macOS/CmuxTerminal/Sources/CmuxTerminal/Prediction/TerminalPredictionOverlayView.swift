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

    public var layout: PredictionOverlayLayout? {
        didSet { if layout != oldValue { needsDisplay = true } }
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
        guard let style, let layout else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: style.foreground,
            // Underlining unconfirmed text is the convention mosh established,
            // and it is the only cue that separates a guess from the truth.
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        // Laid out by offset, not by position in the list: a keystroke typed
        // before the run armed is not drawn but still owns its cell.
        for glyph in layout.glyphs {
            let cell = CGRect(
                x: CGFloat(glyph.offset - layout.leadingOffset) * style.cellSize.width,
                y: 0,
                width: style.cellSize.width,
                height: style.cellSize.height
            )

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
        if let caretOffset = layout.caretOffset {
            style.cursor.setFill()
            CGRect(
                x: CGFloat(caretOffset - layout.leadingOffset) * style.cellSize.width,
                y: 0,
                width: 1,
                height: style.cellSize.height
            ).fill()
        }
    }

    /// Positions the run and shows or hides it in one step.
    ///
    /// - Parameters:
    ///   - glyphs: What to draw, offsets measured from the live cursor.
    ///   - cursorColumn: The live cursor's column on screen.
    ///   - columns: The grid's column count, so the run stops at the margin.
    ///   - cursorOrigin: The cursor cell's frame origin (bottom-left) in the
    ///     host view's coordinates, already converted out of ghostty's
    ///     top-left space.
    /// - Returns: Whether anything is drawn.
    @discardableResult
    public func present(
        glyphs: [PredictedGlyph],
        cursorColumn: Int,
        columns: Int,
        style: Style,
        cursorOrigin: CGPoint
    ) -> Bool {
        guard let layout = PredictionOverlayLayout(
            glyphs: glyphs,
            cursorColumn: cursorColumn,
            columns: columns
        ) else {
            withdraw()
            return false
        }
        self.style = style
        self.layout = layout
        frame = CGRect(
            x: cursorOrigin.x + CGFloat(layout.leadingOffset) * style.cellSize.width,
            y: cursorOrigin.y,
            width: CGFloat(layout.cellCount) * style.cellSize.width,
            height: style.cellSize.height
        )
        isHidden = false
        return true
    }

    /// Hides the run and forgets it.
    public func withdraw() {
        layout = nil
        isHidden = true
    }
}
