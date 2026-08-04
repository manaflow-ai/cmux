import AppKit

/// Owns the file-preview scroll view and draws a line-number gutter beside it.
///
/// The gutter deliberately lives outside `NSScrollView`'s ruler system. Native
/// ruler visibility can make this TextKit 1 document view disappear on macOS 26
/// and has also crashed the app-hosted unit-test process during ruler teardown.
final class FilePreviewTextEditorView: NSView {
    private static let horizontalPadding: CGFloat = 8
    private static let minimumGutterWidth: CGFloat = 38

    let scrollView: NSScrollView
    let textView: SavingTextView

    private var lineNumberIndex: FilePreviewLineNumberIndex
    private var editorBackgroundColor = NSColor.clear
    private var editorForegroundColor = NSColor.labelColor
    private(set) var lineNumberGutterWidth: CGFloat

    init(textView: SavingTextView) {
        self.textView = textView
        scrollView = NSScrollView()
        lineNumberGutterWidth = Self.minimumGutterWidth
        lineNumberIndex = FilePreviewLineNumberIndex(
            text: textView.textStorage?.mutableString ?? (textView.string as NSString)
        )
        super.init(frame: .zero)

        textView.filePreviewEditorView = self
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)

        lineNumberGutterWidth = desiredGutterWidth()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(filePreviewTextStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FilePreviewTextEditorView does not support coder initialization")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        let resolvedGutterWidth = min(lineNumberGutterWidth, bounds.width)
        let nextScrollViewFrame = NSRect(
            x: resolvedGutterWidth,
            y: 0,
            width: max(0, bounds.width - resolvedGutterWidth),
            height: bounds.height
        )
        if scrollView.frame != nextScrollViewFrame {
            scrollView.frame = nextScrollViewFrame
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let gutterRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: min(lineNumberGutterWidth, bounds.width),
            height: bounds.height
        )
        guard gutterRect.intersects(dirtyRect) else { return }

        editorBackgroundColor.setFill()
        gutterRect.intersection(dirtyRect).fill()

        let separator = NSBezierPath()
        separator.lineWidth = 1
        separator.move(to: NSPoint(x: gutterRect.maxX - 0.5, y: dirtyRect.minY))
        separator.line(to: NSPoint(x: gutterRect.maxX - 0.5, y: dirtyRect.maxY))
        editorForegroundColor.withAlphaComponent(0.14).setStroke()
        separator.stroke()

        let font = gutterFont()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: editorForegroundColor.withAlphaComponent(0.52),
            .paragraphStyle: paragraphStyle,
        ]

        for label in visibleLabels() {
            draw(
                label: label,
                dirtyRect: dirtyRect,
                font: font,
                attributes: attributes
            )
        }
    }

    func updateAppearance(backgroundColor: NSColor, foregroundColor: NSColor) {
        editorBackgroundColor = backgroundColor
        editorForegroundColor = foregroundColor
        refresh()
    }

    func refreshFont() {
        refresh()
    }

    func refreshLayout() {
        needsDisplay = true
    }

    @objc private func scrollViewBoundsDidChange(_: Notification) {
        needsDisplay = true
    }

    @objc private func filePreviewTextStorageDidProcessEditing(_ notification: Notification) {
        guard let textStorage = notification.object as? NSTextStorage,
              textStorage.editedMask.contains(.editedCharacters) else { return }
        lineNumberIndex.applyCharacterEdit(
            updatedRange: textStorage.editedRange,
            changeInLength: textStorage.changeInLength,
            updatedText: textStorage.mutableString
        )
        refresh()
    }

    func visibleLabels() -> [(lineNumber: Int, lineFragmentRect: NSRect)] {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return [] }

        let textContainerOrigin = textView.textContainerOrigin
        let textLength = textView.textStorage?.length ?? 0
        let visibleContainerRect = textView.visibleRect.offsetBy(
            dx: -textContainerOrigin.x,
            dy: -textContainerOrigin.y
        )
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleContainerRect,
            in: textContainer
        )

        var labels: [(lineNumber: Int, lineFragmentRect: NSRect)] = []
        if visibleGlyphRange.length > 0 {
            layoutManager.enumerateLineFragments(
                forGlyphRange: visibleGlyphRange
            ) { [weak self] lineRect, _, _, glyphRange, _ in
                guard let self else { return }
                let characterRange = layoutManager.characterRange(
                    forGlyphRange: glyphRange,
                    actualGlyphRange: nil
                )
                guard characterRange.location != NSNotFound,
                      characterRange.location < textLength else { return }

                let lineNumber = lineNumberIndex.lineNumber(
                    atCharacterLocation: characterRange.location
                )
                guard lineNumberIndex.lineStart(forLineNumber: lineNumber)
                    == characterRange.location else {
                    // Wrapped continuation fragments do not repeat the logical
                    // line number.
                    return
                }
                labels.append((
                    lineNumber: lineNumber,
                    lineFragmentRect: lineRect
                ))
            }
        }

        if let trailingLabel = trailingEmptyLineLabel(
            layoutManager: layoutManager,
            textContainer: textContainer
        ) {
            labels.append(trailingLabel)
        }
        return labels
    }

    private func trailingEmptyLineLabel(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> (lineNumber: Int, lineFragmentRect: NSRect)? {
        let textLength = textView.textStorage?.length ?? 0
        guard lineNumberIndex.lineStart(forLineNumber: lineNumberIndex.lineCount)
            == textLength else { return nil }

        let lineRect: NSRect
        if textLength == 0 {
            lineRect = NSRect(
                x: 0,
                y: 0,
                width: 0,
                height: layoutManager.defaultLineHeight(for: textView.font ?? gutterFont())
            )
        } else {
            guard layoutManager.extraLineFragmentTextContainer === textContainer,
                  !layoutManager.extraLineFragmentRect.isEmpty else { return nil }
            lineRect = layoutManager.extraLineFragmentRect
        }

        return (
            lineNumber: lineNumberIndex.lineCount,
            lineFragmentRect: lineRect
        )
    }

    private func refresh() {
        let nextGutterWidth = desiredGutterWidth()
        if abs(lineNumberGutterWidth - nextGutterWidth) > 0.5 {
            lineNumberGutterWidth = nextGutterWidth
            needsLayout = true
        }
        needsDisplay = true
    }

    private func desiredGutterWidth() -> CGFloat {
        let sample = String(repeating: "8", count: max(1, String(lineNumberIndex.lineCount).count))
            as NSString
        let labelWidth = sample.size(withAttributes: [.font: gutterFont()]).width
        return max(
            Self.minimumGutterWidth,
            ceil(labelWidth + (Self.horizontalPadding * 2) + 4)
        )
    }

    private func gutterFont() -> NSFont {
        let textSize = textView.font?.pointSize ?? 13
        return NSFont.monospacedDigitSystemFont(
            ofSize: max(8, textSize - 1),
            weight: .regular
        )
    }

    private func draw(
        label: (lineNumber: Int, lineFragmentRect: NSRect),
        dirtyRect: NSRect,
        font: NSFont,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let textOrigin = textView.textContainerOrigin
        let editorPoint = convert(
            NSPoint(
                x: textOrigin.x,
                y: textOrigin.y + label.lineFragmentRect.minY
            ),
            from: textView
        )
        let labelHeight = font.ascender - font.descender + font.leading
        let labelRect = NSRect(
            x: bounds.minX + Self.horizontalPadding,
            y: editorPoint.y + max(0, (label.lineFragmentRect.height - labelHeight) / 2),
            width: max(0, lineNumberGutterWidth - (Self.horizontalPadding * 2) - 4),
            height: labelHeight
        )
        guard labelRect.intersects(dirtyRect) else { return }
        (String(label.lineNumber) as NSString).draw(in: labelRect, withAttributes: attributes)
    }
}
