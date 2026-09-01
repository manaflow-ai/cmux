import AppKit
import CmuxFoundation

/// Draws current-line highlight and indent guides over a TextKit 1 text view.
///
/// Hits are ignored so clicks reach the text view. The overlay is a subview of
/// the text view so it scrolls with the document.
final class FilePreviewEditorChromeOverlay: NSView {
    weak var textView: NSTextView?
    var showsCurrentLine = true
    var showsIndentGuides = true
    var tabWidth = 4
    var currentLineColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12)
    var indentGuideColor = NSColor.separatorColor.withAlphaComponent(0.55)

    deinit {}

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        if showsCurrentLine {
            drawCurrentLine(in: textView, layoutManager: layoutManager, textContainer: textContainer)
        }
        if showsIndentGuides {
            drawIndentGuides(
                in: dirtyRect,
                textView: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
        }
    }

    static func installed(in textView: NSTextView) -> FilePreviewEditorChromeOverlay? {
        textView.subviews.compactMap { $0 as? FilePreviewEditorChromeOverlay }.first
    }

    func syncFrame(to textView: NSTextView) {
        let next = textView.bounds
        if frame != next {
            frame = next
        }
        needsDisplay = true
    }

    private func drawCurrentLine(
        in textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) {
        let selected = textView.selectedRange()
        guard selected.length == 0 else { return }
        let stringLength = (textView.string as NSString).length
        let location = min(max(selected.location, 0), stringLength)
        let glyphCount = layoutManager.numberOfGlyphs
        // TextKit has no glyph for an empty buffer. At EOF it may return the
        // insertion-point glyph index (the glyph count), which is not a valid
        // argument to `lineFragmentRect(forGlyphAt:)`. Use the final real
        // character for that case so a trailing empty line can be painted one
        // fragment below it.
        if stringLength == 0 {
            fillCurrentLineBand(
                atY: textView.textContainerOrigin.y,
                height: textView.font?.boundingRectForFont.height ?? 16,
                in: textView
            )
            return
        }
        guard glyphCount > 0 else { return }
        let characterIndex = location >= stringLength ? stringLength - 1 : location
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        guard glyphIndex >= 0, glyphIndex < glyphCount else { return }
        var lineRange = NSRange()
        var fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &lineRange,
            withoutAdditionalLayout: true
        )
        if fragment.height <= 0 || !fragment.minY.isFinite {
            // Non-contiguous layout may not have realized this caret's
            // fragment yet. Ask TextKit to lay out this one valid glyph before
            // giving up; never call the API with the EOF insertion index.
            fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineRange,
                withoutAdditionalLayout: false
            )
        }
        guard fragment.height > 0, fragment.minY.isFinite else { return }
        let isTrailingEmptyLine = location == stringLength
            && stringLength > 0
            && (textView.string as NSString).character(at: stringLength - 1) == 10
        let origin = textView.textContainerOrigin
        let y = fragment.minY + origin.y + (isTrailingEmptyLine ? fragment.height : 0)
        fillCurrentLineBand(
            atY: y,
            height: max(fragment.height, textView.font?.boundingRectForFont.height ?? 16),
            in: textView
        )
    }

    private func fillCurrentLineBand(atY y: CGFloat, height: CGFloat, in textView: NSTextView) {
        let band = NSRect(
            x: 0,
            y: y,
            width: max(bounds.width, textView.bounds.width),
            height: max(height, 1)
        )
        currentLineColor.setFill()
        band.fill()
    }

    private func drawIndentGuides(
        in dirtyRect: NSRect,
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) {
        let font = textView.font
            ?? GlobalFontMagnification.monospacedSystemFont(ofSize: 13, weight: .regular)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        guard spaceWidth > 0.5 else { return }

        let origin = textView.textContainerOrigin
        let queryRect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: queryRect, in: textContainer)
        let nsString = textView.string as NSString
        let columns = max(1, tabWidth)
        indentGuideColor.setStroke()

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, usedRect, _, fragmentGlyphRange, _ in
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            guard characterRange.location == 0
                    || nsString.character(at: characterRange.location - 1) == 10 else {
                return
            }
            let indentColumns = Self.leadingIndentColumns(
                in: nsString,
                lineStart: characterRange.location,
                tabWidth: columns
            )
            guard indentColumns >= columns else { return }
            var column = columns
            while column <= indentColumns {
                let guideX = origin.x + CGFloat(column) * spaceWidth
                let path = NSBezierPath()
                path.lineWidth = 1
                path.move(to: NSPoint(x: guideX + 0.5, y: usedRect.minY + origin.y))
                path.line(to: NSPoint(x: guideX + 0.5, y: usedRect.maxY + origin.y))
                path.stroke()
                column += columns
            }
        }
    }

    static func leadingIndentColumns(
        in string: NSString,
        lineStart: Int,
        tabWidth: Int
    ) -> Int {
        var columns = 0
        var index = lineStart
        let length = string.length
        let tab = max(1, tabWidth)
        while index < length {
            let character = string.character(at: index)
            if character == 32 {
                columns += 1
            } else if character == 9 {
                columns = ((columns / tab) + 1) * tab
            } else {
                break
            }
            index += 1
        }
        return columns
    }
}
