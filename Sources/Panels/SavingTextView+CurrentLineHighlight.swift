import AppKit

extension SavingTextView {
    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightsCurrentLine,
              let lineRect = currentLineHighlightRect(),
              lineRect.intersects(rect) else { return }
        currentLineHighlightColor.setFill()
        lineRect.intersection(rect).fill()
    }

    /// Full-width rect of the logical line containing the insertion point, or
    /// nil while a range of text is selected (the selection highlight already
    /// marks the location, matching Zed/Xcode behavior).
    private func currentLineHighlightRect() -> NSRect? {
        let selection = selectedRange()
        guard selection.length == 0,
              let layoutManager,
              let textContainer else { return nil }
        let text = string as NSString
        let caret = min(selection.location, text.length)

        var fragmentRect: NSRect
        let caretOnTrailingEmptyLine = caret == text.length
            && (text.length == 0 || text.character(at: text.length - 1) == 10)
        if caretOnTrailingEmptyLine {
            fragmentRect = layoutManager.extraLineFragmentRect
            if fragmentRect.height <= 0 {
                let lineHeight = layoutManager.defaultLineHeight(
                    for: font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                )
                fragmentRect = NSRect(x: 0, y: 0, width: 0, height: lineHeight)
            }
        } else {
            let paragraphRange = text.paragraphRange(for: NSRange(location: caret, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: paragraphRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return nil }
            fragmentRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        }

        var lineRect = fragmentRect
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerInset.height
        return lineRect
    }
}
