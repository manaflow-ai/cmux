import AppKit
import CmuxSyntaxHighlighting

/// TextKit 1 line-number ruler. Draws only fragments that intersect the viewport.
///
/// Fills with the editor surface so numbers sit in the margin instead of on
/// AppKit's default contrasting ruler strip.
final class FilePreviewLineNumberGutterView: NSRulerView {
    var tokenTheme: TokenTheme = .dark {
        didSet { needsDisplay = true }
    }
    var editorBackgroundColor: NSColor = .clear {
        didSet { applySurfaceFill() }
    }
    var drawsEditorBackground = true {
        didSet { applySurfaceFill() }
    }
    private static let horizontalPadding: CGFloat = 10

    private var lineIndex = FilePreviewLineIndex(string: "")
    private var indexedContentRevision: Int?

    override var isOpaque: Bool {
        drawsEditorBackground && editorBackgroundColor.alphaComponent >= 0.999
    }

    override var wantsUpdateLayer: Bool { false }

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
        ruleThickness = 36
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        wantsLayer = true
        applySurfaceFill()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    func reloadLineIndex(
        from string: String,
        contentRevision: Int,
        textFont: NSFont?
    ) {
        // `0` is the compatibility value for panels that do not publish
        // revisions, so retain correctness by rebuilding for those callers.
        if contentRevision == 0 || indexedContentRevision != contentRevision {
            lineIndex = FilePreviewLineIndex(string: string)
            indexedContentRevision = contentRevision
        }
        updateRuleThickness(for: textFont)
        needsDisplay = true
    }

    private func updateRuleThickness(for textFont: NSFont?) {
        let font = labelFont(for: textFont)
        let digits = max(2, String(lineIndex.lineCount).count)
        let labelWidth = (String(repeating: "8", count: digits) as NSString).size(
            withAttributes: [.font: font]
        ).width
        let nextThickness = ceil(labelWidth) + Self.horizontalPadding
        if abs(ruleThickness - nextThickness) > 0.5 {
            ruleThickness = nextThickness
        }
    }

    private func labelFont(for textFont: NSFont?) -> NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: max(9, (textFont?.pointSize ?? 13) * 0.78),
            weight: .regular
        )
    }

    private func applySurfaceFill() {
        wantsLayer = true
        layer?.backgroundColor = drawsEditorBackground
            ? editorBackgroundColor.cgColor
            : NSColor.clear.cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Do not call super — NSRulerView paints a system control strip
        // that reads as a second background next to the editor.
        if drawsEditorBackground {
            editorBackgroundColor.setFill()
            bounds.fill()
        } else {
            NSColor.clear.setFill()
            bounds.fill()
        }
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let font = labelFont(for: textView.font)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let selected = textView.selectedRange()
        let currentLine = selected.length == 0
            ? lineIndex.lineNumber(containingUTF16Offset: selected.location)
            : nil

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
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
                .paragraphStyle: paragraphStyle
            ]
            NSString(string: String(lineNumber)).draw(in: labelRect, withAttributes: attributes)
        }
    }
}
