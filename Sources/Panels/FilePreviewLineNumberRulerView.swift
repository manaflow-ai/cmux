import AppKit

extension FilePreviewTextEditor {
    static func applyLineNumberRuler(
        on scrollView: NSScrollView,
        textView: NSTextView,
        editor: Self
    ) {
        configureLineNumberRuler(
            on: scrollView,
            textView: textView,
            showsLineNumbers: editor.showsLineNumbers,
            backgroundColor: editor.themeBackgroundColor,
            foregroundColor: editor.themeForegroundColor,
            drawsBackground: editor.drawsBackground
        )
    }

    static func configureLineNumberRuler(
        on scrollView: NSScrollView,
        textView: NSTextView,
        showsLineNumbers: Bool,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        drawsBackground: Bool
    ) {
        guard showsLineNumbers else {
            scrollView.hasVerticalRuler = false
            scrollView.rulersVisible = false
            scrollView.verticalRulerView = nil
            return
        }

        let ruler: FilePreviewLineNumberRulerView
        if let existing = scrollView.verticalRulerView as? FilePreviewLineNumberRulerView {
            ruler = existing
        } else {
            ruler = FilePreviewLineNumberRulerView(scrollView: scrollView)
            scrollView.verticalRulerView = ruler
        }
        ruler.attach(to: scrollView, textView: textView)
        ruler.backgroundColor = drawsBackground ? backgroundColor : .clear
        ruler.foregroundColor = foregroundColor.withAlphaComponent(0.45)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
    }

    static func updateLineNumberRulerTheme(
        on scrollView: NSScrollView,
        backgroundColor: NSColor,
        foregroundColor: NSColor
    ) {
        guard let ruler = scrollView.verticalRulerView as? FilePreviewLineNumberRulerView else {
            return
        }
        ruler.backgroundColor = backgroundColor
        ruler.foregroundColor = foregroundColor.withAlphaComponent(0.45)
    }
}

final class FilePreviewLineNumberRulerView: NSRulerView {
    private weak var trackedTextView: NSTextView?
    private weak var trackedScrollView: NSScrollView?
    private var visibleBoundsObserver: NSObjectProtocol?
    private var lineStarts: [Int] = [0]
    private var lineCacheNeedsRebuild = true

    var foregroundColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    var backgroundColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = FilePreviewTextEditorLayout.minimumLineNumberGutterWidth
        clientView = scrollView.documentView
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if let visibleBoundsObserver {
            NotificationCenter.default.removeObserver(visibleBoundsObserver)
        }
    }

    override var requiredThickness: CGFloat {
        rebuildLineStartsIfNeeded()
        let digits = max(2, String(max(1, lineStarts.count)).count)
        let font = FilePreviewTextEditorLayout.lineNumberFont
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: font]).width
        return max(FilePreviewTextEditorLayout.minimumLineNumberGutterWidth, ceil(width + 18))
    }

    func attach(to scrollView: NSScrollView, textView: NSTextView) {
        if trackedScrollView !== scrollView, let visibleBoundsObserver {
            NotificationCenter.default.removeObserver(visibleBoundsObserver)
            self.visibleBoundsObserver = nil
        }
        trackedScrollView = scrollView
        trackedTextView = textView
        clientView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        if visibleBoundsObserver == nil {
            visibleBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.needsDisplay = true
            }
        }
        invalidateLineNumbers()
    }

    func invalidateLineNumbers() {
        lineCacheNeedsRebuild = true
        invalidateHashMarks()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = trackedTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            backgroundColor.setFill()
            bounds.fill()
            return
        }

        backgroundColor.setFill()
        bounds.fill()
        rebuildLineStartsIfNeeded()

        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        guard glyphRange.length > 0 else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: FilePreviewTextEditorLayout.lineNumberFont,
            .foregroundColor: foregroundColor,
        ]
        var glyphIndex = glyphRange.location
        let maxGlyphIndex = NSMaxRange(glyphRange)
        while glyphIndex < maxGlyphIndex {
            var effectiveRange = NSRange(location: 0, length: 0)
            let fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &effectiveRange,
                withoutAdditionalLayout: true
            )
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineIndex = sourceLineIndex(containingCharacterAt: characterIndex)
            if lineFragment(effectiveRange, containsLineStartAt: lineStarts[lineIndex], layoutManager: layoutManager) {
                drawLineNumber(
                    lineIndex + 1,
                    fragmentRect: fragmentRect,
                    textView: textView,
                    attributes: attributes
                )
            }

            let nextGlyphIndex = NSMaxRange(effectiveRange)
            glyphIndex = nextGlyphIndex > glyphIndex ? nextGlyphIndex : glyphIndex + 1
        }
    }

    private func rebuildLineStartsIfNeeded() {
        guard lineCacheNeedsRebuild, let text = trackedTextView?.string else { return }
        var starts: [Int] = [0]
        starts.reserveCapacity(max(1, text.utf16.count / 48))
        var index = 0
        for codeUnit in text.utf16 {
            index += 1
            if codeUnit == 10 {
                starts.append(index)
            }
        }
        lineStarts = starts
        lineCacheNeedsRebuild = false
        ruleThickness = requiredThickness
    }

    private func sourceLineIndex(containingCharacterAt characterIndex: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= characterIndex {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(0, low - 1)
    }

    private func lineFragment(
        _ fragmentGlyphRange: NSRange,
        containsLineStartAt characterIndex: Int,
        layoutManager: NSLayoutManager
    ) -> Bool {
        guard layoutManager.numberOfGlyphs > 0,
              let textLength = trackedTextView?.string.utf16.count,
              textLength > 0 else { return false }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(characterIndex, textLength - 1))
        return NSLocationInRange(glyphIndex, fragmentGlyphRange)
    }

    private func drawLineNumber(
        _ number: Int,
        fragmentRect: NSRect,
        textView: NSTextView,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attributes)
        let originInTextView = NSPoint(
            x: textView.textContainerOrigin.x,
            y: textView.textContainerOrigin.y + fragmentRect.minY
        )
        let originInRuler = convert(originInTextView, from: textView)
        let x = max(2, bounds.width - size.width - 8)
        let y = originInRuler.y + max(0, (fragmentRect.height - size.height) / 2)
        label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }
}

extension NSTextView {
    func invalidateFilePreviewLineNumberRuler() {
        (enclosingScrollView?.verticalRulerView as? FilePreviewLineNumberRulerView)?
            .invalidateLineNumbers()
    }
}
