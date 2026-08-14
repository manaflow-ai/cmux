import AppKit
import CmuxSyntaxHighlighting

/// TextKit 1 line-number ruler. Draws only fragments that intersect the viewport.
final class FilePreviewLineNumberGutterView: NSRulerView {
    var tokenTheme: TokenTheme = .dark {
        didSet { needsDisplay = true }
    }
    private var lineIndex = FilePreviewLineIndex(string: "")

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
        ruleThickness = 36
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    func reloadLineIndex(from string: String) {
        lineIndex = FilePreviewLineIndex(string: string)
        let digits = max(2, String(lineIndex.lineCount).count)
        let nextThickness = CGFloat(digits) * 8 + 16
        if abs(ruleThickness - nextThickness) > 0.5 {
            ruleThickness = nextThickness
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: max(9, (textView.font?.pointSize ?? 13) * 0.78),
            weight: .regular
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let selected = textView.selectedRange()
        let currentLine = selected.length == 0
            ? lineIndex.lineNumber(containingUTF16Offset: selected.location)
            : nil

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, usedRect, _, fragmentGlyphRange, _ in
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            let lineNumber = self.lineIndex.lineNumber(
                containingUTF16Offset: characterRange.location
            )
            guard self.lineIndex.offset(forLine: lineNumber) == characterRange.location else {
                return
            }
            let documentPoint = NSPoint(
                x: 0,
                y: usedRect.minY + textView.textContainerOrigin.y
            )
            let rulerPoint = self.convert(documentPoint, from: textView)
            let labelRect = NSRect(
                x: 4,
                y: rulerPoint.y,
                width: max(0, self.ruleThickness - 10),
                height: max(usedRect.height, font.capHeight + 4)
            )
            let color = currentLine == lineNumber
                ? self.tokenTheme.gutterCurrentLineColor
                : self.tokenTheme.gutterDefaultColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]
            NSString(string: String(lineNumber)).draw(in: labelRect, withAttributes: attributes)
        }
    }
}
