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
            drawCurrentLine(in: textView, layoutManager: layoutManager)
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
        layoutManager: NSLayoutManager
    ) {
        let selected = textView.selectedRange()
        guard selected.length == 0 else { return }
        let stringLength = (textView.string as NSString).length
        let location = min(max(selected.location, 0), stringLength)
        let glyphCount = layoutManager.numberOfGlyphs
        let origin = textView.textContainerOrigin
        let fallbackHeight = max(textView.font?.boundingRectForFont.height ?? 16, 1)
        let nsString = textView.string as NSString

        // TextKit represents an empty buffer and the line after a terminal
        // newline with `extraLineFragmentRect`, not a glyph. Prefer that
        // explicit rect so wrapped lines use their real visual position.
        let isExtraLine = stringLength == 0
            || (location == stringLength && Self.endsWithLineBreak(nsString))
        if isExtraLine {
            let extra = layoutManager.extraLineFragmentRect
            if Self.isUsableLineRect(extra) {
                fillCurrentLineBand(
                    atY: extra.minY + origin.y,
                    height: max(extra.height, fallbackHeight),
                    in: textView
                )
            } else if stringLength == 0 {
                // A freshly created TextKit stack may not have populated the
                // extra-line rect yet, but the empty editor still has a valid
                // first line at the text-container origin.
                fillCurrentLineBand(atY: origin.y, height: fallbackHeight, in: textView)
            } else if glyphCount > 0 {
                // If the extra-line metadata has not been populated yet, use
                // the last realized fragment. Do not force layout from draw:
                // a long non-contiguous line could otherwise block the main
                // actor while the overlay is painting.
                var lastRange = NSRange()
                let lastFragment = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphCount - 1,
                    effectiveRange: &lastRange,
                    withoutAdditionalLayout: true
                )
                if Self.isUsableLineRect(lastFragment) {
                    fillCurrentLineBand(
                        atY: lastFragment.maxY + origin.y,
                        height: max(lastFragment.height, fallbackHeight),
                        in: textView
                    )
                }
            }
            return
        }

        // At EOF in a non-empty, non-newline-terminated buffer, use the final
        // real character. Never pass the insertion-point glyph index.
        guard glyphCount > 0 else { return }
        let characterIndex = min(location, stringLength - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        guard glyphIndex >= 0, glyphIndex < glyphCount else { return }
        var lineRange = NSRange()
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &lineRange,
            withoutAdditionalLayout: true
        )
        // `allowsNonContiguousLayout` can leave a caret's fragment unrealized.
        // Never force a potentially huge synchronous layout from draw; the
        // next TextKit invalidation will repaint after that fragment is ready.
        guard Self.isUsableLineRect(fragment) else { return }
        let y = fragment.minY + origin.y
        fillCurrentLineBand(
            atY: y,
            height: max(fragment.height, fallbackHeight),
            in: textView
        )
    }

    private static func isUsableLineRect(_ rect: NSRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.height > 0
    }

    private static func endsWithLineBreak(_ string: NSString) -> Bool {
        guard string.length > 0 else { return false }
        let last = string.character(at: string.length - 1)
        return last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029
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
                    || Self.isLineBreak(nsString.character(at: characterRange.location - 1)) else {
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

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
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
