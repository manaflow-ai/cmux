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
        ruler.currentLineForegroundColor = foregroundColor.withAlphaComponent(0.85)
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
        ruler.currentLineForegroundColor = foregroundColor.withAlphaComponent(0.85)
    }
}

final class FilePreviewLineNumberRulerView: NSRulerView {
    private weak var trackedTextView: NSTextView?
    private weak var trackedScrollView: NSScrollView?
    private weak var trackedTextStorage: NSTextStorage?
    private var visibleBoundsObserver: NSObjectProtocol?
    private var lineStarts: [Int] = [0]
    private var lineCacheNeedsRebuild = true
    private var pendingThicknessUpdate = false

    var foregroundColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    var currentLineForegroundColor: NSColor = .labelColor {
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
        if trackedTextStorage?.delegate === self {
            trackedTextStorage?.delegate = nil
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
        let isReattachingSameViews = trackedScrollView === scrollView
            && trackedTextView === textView
            && trackedTextStorage === textView.textStorage
        trackedScrollView = scrollView
        trackedTextView = textView
        clientView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        // Track edits at the text-storage level so the line-start cache can be
        // patched incrementally instead of rescanning the whole document on
        // every keystroke (the reason line numbers were previously disabled
        // for the markdown editor).
        if trackedTextStorage !== textView.textStorage {
            if trackedTextStorage?.delegate === self {
                trackedTextStorage?.delegate = nil
            }
            trackedTextStorage = textView.textStorage
        }
        if trackedTextStorage?.delegate == nil {
            trackedTextStorage?.delegate = self
        }

        if visibleBoundsObserver == nil {
            visibleBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.needsDisplay = true
            }
        }
        // `attach` re-runs on every SwiftUI update; only pay for a full rescan
        // when the tracked views actually changed.
        if !isReattachingSameViews {
            invalidateLineNumbers()
        }
    }

    func invalidateLineNumbers() {
        lineCacheNeedsRebuild = true
        invalidateHashMarks()
        needsDisplay = true
    }

    /// True when incremental edit tracking is live for `storage`, i.e. the
    /// cache stays correct without full invalidations from `textDidChange`.
    func isTrackingTextStorage(_ storage: NSTextStorage?) -> Bool {
        storage != nil && trackedTextStorage === storage && storage?.delegate === self
    }

    /// Test hook: the cached line-start offsets (UTF-16), rebuilding first if
    /// a full invalidation is pending. Lets tests verify the incremental
    /// edit tracking against a naive whole-document scan.
    func lineStartsForTesting() -> [Int] {
        rebuildLineStartsIfNeeded()
        return lineStarts
    }

    /// Patches `lineStarts` in place for a single text-storage edit.
    ///
    /// `editedRange` is the range of the replacement in the NEW text and
    /// `delta` the length change, exactly as reported by
    /// `textStorage(_:didProcessEditing:range:changeInLength:)`. Cost is
    /// O(edited text + lines after the edit) rather than O(document), which is
    /// what keeps the gutter viable on every keystroke.
    private func applyIncrementalEdit(editedRange: NSRange, changeInLength delta: Int, storage: NSTextStorage) {
        guard !lineCacheNeedsRebuild else {
            needsDisplay = true
            return
        }
        let replacedOldLength = editedRange.length - delta
        guard replacedOldLength >= 0 else {
            invalidateLineNumbers()
            return
        }

        // A line start `s` (s > 0) marks a newline at `s - 1`. Drop starts
        // whose newline sat inside the replaced range of the OLD text:
        // s - 1 in [location, location + replacedOldLength).
        let removeFrom = firstLineStartIndex(atLeast: editedRange.location + 1)
        let removeTo = firstLineStartIndex(atLeast: editedRange.location + replacedOldLength + 1)

        var insertedStarts: [Int] = []
        if editedRange.length > 0 {
            let newText = (storage.string as NSString).substring(with: editedRange)
            var offset = 0
            for codeUnit in newText.utf16 {
                offset += 1
                if codeUnit == 10 {
                    insertedStarts.append(editedRange.location + offset)
                }
            }
        }

        var tail = Array(lineStarts[removeTo...])
        if delta != 0 {
            for index in tail.indices {
                tail[index] += delta
            }
        }
        lineStarts.replaceSubrange(removeFrom..., with: insertedStarts + tail)

        scheduleThicknessUpdateIfNeeded()
        needsDisplay = true
    }

    /// First index in `lineStarts` whose value is >= `value` (binary search).
    private func firstLineStartIndex(atLeast value: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// Grows/shrinks the gutter outside `processEditing` — resizing the ruler
    /// mid-edit would trigger layout while the layout manager is busy.
    private func scheduleThicknessUpdateIfNeeded() {
        guard !pendingThicknessUpdate else { return }
        pendingThicknessUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingThicknessUpdate = false
            let needed = self.requiredThickness
            if abs(needed - self.ruleThickness) > 0.5 {
                self.ruleThickness = needed
            }
        }
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

        let attributes: [NSAttributedString.Key: Any] = [
            .font: FilePreviewTextEditorLayout.lineNumberFont,
            .foregroundColor: foregroundColor,
        ]
        let currentLineAttributes: [NSAttributedString.Key: Any] = [
            .font: FilePreviewTextEditorLayout.lineNumberFont,
            .foregroundColor: currentLineForegroundColor,
        ]
        let currentLineIndex = self.currentLineIndex(in: textView)

        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
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
                    attributes: lineIndex == currentLineIndex ? currentLineAttributes : attributes
                )
            }

            let nextGlyphIndex = NSMaxRange(effectiveRange)
            glyphIndex = nextGlyphIndex > glyphIndex ? nextGlyphIndex : glyphIndex + 1
        }

        // The trailing empty line (empty document, or a document ending in a
        // newline) has no glyphs, so the loop above never numbers it.
        if layoutManager.extraLineFragmentTextContainer != nil {
            let lastLineIndex = lineStarts.count - 1
            drawLineNumber(
                lastLineIndex + 1,
                fragmentRect: layoutManager.extraLineFragmentRect,
                textView: textView,
                attributes: lastLineIndex == currentLineIndex ? currentLineAttributes : attributes
            )
        }
    }

    /// Source line containing the insertion point, or nil while a range of
    /// text is selected (matching how editors dim the gutter during selection).
    private func currentLineIndex(in textView: NSTextView) -> Int? {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        return sourceLineIndex(containingCharacterAt: selection.location)
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

extension FilePreviewLineNumberRulerView: NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        applyIncrementalEdit(editedRange: editedRange, changeInLength: delta, storage: textStorage)
    }
}

extension NSTextView {
    func invalidateFilePreviewLineNumberRuler() {
        (enclosingScrollView?.verticalRulerView as? FilePreviewLineNumberRulerView)?
            .invalidateLineNumbers()
    }
}
