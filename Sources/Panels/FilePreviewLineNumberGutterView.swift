import AppKit
import CmuxFilePreviewCore
import CmuxSyntaxHighlighting

/// TextKit 1 line-number ruler. Draws only fragments that intersect the viewport.
///
/// Fills with the editor surface so numbers sit in the margin instead of on
/// AppKit's default contrasting ruler strip.
///
/// The line index is maintained incrementally from text-storage edit
/// notifications (`NSText.didProcessEditingNotification`) so typing never
/// rescans the whole buffer; a keystroke splices a few line-start offsets
/// instead of walking up to 16 MB of text on the main actor.
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
    /// Git markers for the file. A tracked file reserves the stripe column
    /// even without changes, so the first edit never shifts the text.
    var gitMarkers = FilePreviewGitGutterMarkers.untracked {
        didSet {
            guard gitMarkers != oldValue else { return }
            updateRuleThickness(for: (clientView as? NSTextView)?.font)
            needsDisplay = true
        }
    }
    private static let horizontalPadding: CGFloat = 10
    /// Width of a change stripe.
    private static let changeStripeWidth: CGFloat = 3
    /// Gap between the line number and the stripe.
    private static let changeStripeGap: CGFloat = 3
    /// Extra ruler width reserved while the file is tracked.
    ///
    /// Drawing positions derive from the label's trailing edge, so this
    /// reservation and the drawn stripe cannot drift apart.
    private static var changeStripeInset: CGFloat { changeStripeWidth + changeStripeGap }

    private var lineIndex = FilePreviewLineIndex(string: "")
    /// Set when edits were skipped (ruler hidden) and the index must be
    /// rebuilt before its next use.
    private var needsFullRebuild = true
    private var observedStorage: NSTextStorage?
    private var storageObserver: (any NSObjectProtocol)?

    override var isOpaque: Bool {
        drawsEditorBackground && editorBackgroundColor.alphaComponent >= 0.999
    }

    override var wantsUpdateLayer: Bool { false }

    override var clientView: NSView? {
        didSet { observeStorage(of: clientView) }
    }

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

    deinit {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
    }

    /// Reconciles the index against `string`.
    ///
    /// While storage observation is live, per-edit increments keep the index
    /// exact and this is a no-op scan; a full rebuild happens only after
    /// skipped edits (ruler hidden) or on first attach.
    func reloadLineIndex(from string: String, textFont: NSFont?) {
        if needsFullRebuild || observedStorage == nil {
            lineIndex = FilePreviewLineIndex(string: string)
            needsFullRebuild = false
        }
        updateRuleThickness(for: textFont)
        needsDisplay = true
    }

    /// Subscribes to the client text view's storage edits.
    private func observeStorage(of view: NSView?) {
        if let storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
        storageObserver = nil
        observedStorage = nil
        guard let textView = view as? NSTextView,
              let storage = textView.textStorage else {
            needsFullRebuild = true
            return
        }
        observedStorage = storage
        if scrollView?.rulersVisible == true {
            lineIndex = FilePreviewLineIndex(string: textView.string)
            needsFullRebuild = false
        } else {
            // Keep the index lazy while line numbers are disabled. A large
            // hidden preview should not allocate line metadata it cannot draw.
            needsFullRebuild = true
        }
        updateRuleThickness(for: textView.font)
        // `queue: nil` delivers synchronously on the posting (main) thread, so
        // the index is exact before the next layout/draw pass reads it.
        storageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.applyStorageEdit(from: notification)
            }
        }
    }

    /// Applies one storage edit to the index. Skips maintenance while the
    /// ruler is hidden (the index is unread then) and flags a rebuild for the
    /// next time it becomes visible.
    private func applyStorageEdit(from notification: Notification) {
        guard scrollView?.rulersVisible == true else {
            needsFullRebuild = true
            return
        }
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let range = storage.editedRange
        let replacement = (storage.string as NSString).substring(with: range)
        lineIndex.applyEdit(
            atUTF16Location: range.location,
            replacingUTF16Length: range.length - storage.changeInLength,
            replacement: replacement
        )
        updateRuleThickness(for: (clientView as? NSTextView)?.font)
        needsDisplay = true
    }

    private func updateRuleThickness(for textFont: NSFont?) {
        let font = labelFont(for: textFont)
        let digits = max(2, String(lineIndex.lineCount).count)
        let labelWidth = (String(repeating: "8", count: digits) as NSString).size(
            withAttributes: [.font: font]
        ).width
        let stripeInset = gitMarkers.isTracked ? Self.changeStripeInset : 0
        let nextThickness = ceil(labelWidth) + Self.horizontalPadding + stripeInset
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
        let glyphQueryRect = visibleRect.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: glyphQueryRect, in: textContainer)
        let font = labelFont(for: textView.font)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let selected = textView.selectedRange()
        let currentLine = selected.length == 0
            ? lineIndex.lineNumber(containingUTF16Offset: selected.location)
            : nil
        let lineCount = lineIndex.lineCount
        var drewTrailingLine = false

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
            let characterRange = layoutManager.characterRange(
                forGlyphRange: fragmentGlyphRange,
                actualGlyphRange: nil
            )
            let lineNumber = self.lineIndex.lineNumber(
                containingUTF16Offset: characterRange.location
            )
            let fragmentY = usedRect.minY + textView.textContainerOrigin.y
            let startsLine = self.lineIndex.offset(forLine: lineNumber) == characterRange.location
            // Paint every fragment of a wrapped line so the stripe stays continuous.
            self.drawGitChangeStripe(
                for: lineNumber,
                atTextViewY: fragmentY,
                height: usedRect.height,
                in: textView,
                font: font,
                startsLine: startsLine
            )
            guard startsLine else { return }
            self.drawLineNumber(
                lineNumber,
                atTextViewY: fragmentY,
                height: usedRect.height,
                in: textView,
                font: font,
                paragraphStyle: paragraphStyle,
                currentLine: currentLine
            )
            drewTrailingLine = drewTrailingLine || lineNumber == lineCount
        }

        let string = textView.string as NSString
        if layoutManager.numberOfGlyphs == 0, string.length == 0 {
            // An empty document has a valid logical line but no glyph fragment
            // for TextKit to enumerate. Paint its first line directly without
            // asking `lineFragmentRect` for an invalid glyph.
            let emptyLineHeight = textView.font?.boundingRectForFont.height ?? 16
            self.drawGitChangeStripe(
                for: 1,
                atTextViewY: textView.textContainerOrigin.y,
                height: emptyLineHeight,
                in: textView,
                font: font,
                startsLine: true
            )
            self.drawLineNumber(
                1,
                atTextViewY: textView.textContainerOrigin.y,
                height: emptyLineHeight,
                in: textView,
                font: font,
                paragraphStyle: paragraphStyle,
                currentLine: currentLine
            )
        } else if !drewTrailingLine, Self.endsWithLineBreak(string) {
            // The final empty line after a newline has no glyph of its own.
            // TextKit exposes its actual visual position through the extra
            // line fragment; this remains correct when the preceding logical
            // line wraps into multiple visual fragments.
            let fallbackHeight = max(textView.font?.boundingRectForFont.height ?? 16, 1)
            let extra = layoutManager.extraLineFragmentRect
            let trailingRect: NSRect?
            if Self.isUsableLineRect(extra) {
                trailingRect = extra
            } else if layoutManager.numberOfGlyphs > 0 {
                // A non-contiguous layout may not have populated the extra
                // rect yet. Use the last realized fragment if available; do
                // not force a potentially huge synchronous layout in draw.
                var lastRange = NSRange()
                let lastFragment = layoutManager.lineFragmentRect(
                    forGlyphAt: layoutManager.numberOfGlyphs - 1,
                    effectiveRange: &lastRange,
                    withoutAdditionalLayout: true
                )
                trailingRect = Self.isUsableLineRect(lastFragment)
                    ? NSRect(
                        x: lastFragment.minX,
                        y: lastFragment.maxY,
                        width: lastFragment.width,
                        height: max(lastFragment.height, fallbackHeight)
                    )
                    : nil
            } else {
                trailingRect = nil
            }

            if let trailingRect {
                let y = trailingRect.minY + textView.textContainerOrigin.y
                let viewRect = textView.visibleRect
                let visibleTrailingRect = NSRect(
                    x: viewRect.minX,
                    y: y,
                    width: max(1, viewRect.width),
                    height: max(trailingRect.height, fallbackHeight)
                )
                if NSIntersectsRect(visibleTrailingRect, viewRect) {
                    self.drawGitChangeStripe(
                        for: lineCount,
                        atTextViewY: y,
                        height: max(trailingRect.height, fallbackHeight),
                        in: textView,
                        font: font,
                        startsLine: true
                    )
                    self.drawLineNumber(
                        lineCount,
                        atTextViewY: y,
                        height: max(trailingRect.height, fallbackHeight),
                        in: textView,
                        font: font,
                        paragraphStyle: paragraphStyle,
                        currentLine: currentLine
                    )
                }
            }
        }
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

    private func drawLineNumber(
        _ lineNumber: Int,
        atTextViewY y: CGFloat,
        height: CGFloat,
        in textView: NSTextView,
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        currentLine: Int?
    ) {
        let documentPoint = NSPoint(x: 0, y: y)
        let rulerPoint = convert(documentPoint, from: textView)
        let lineHeight = max(height, font.capHeight + 4)
        let labelRect = NSRect(
            x: 4,
            y: rulerPoint.y,
            width: labelTrailingEdge - 4,
            height: lineHeight
        )
        let color = currentLine == lineNumber
            ? tokenTheme.gutterCurrentLineColor
            : tokenTheme.gutterDefaultColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        NSString(string: String(lineNumber)).draw(in: labelRect, withAttributes: attributes)
    }

    /// Paints a git change marker at the trailing edge of the line number.
    ///
    /// - Added and modified lines get a full-height stripe.
    /// - Removed draws a short marker across the line's top edge.
    /// - RemovedAtEnd draws it across the line's bottom edge.
    /// - Edge markers draw only on the first fragment of a wrapped line.
    private func drawGitChangeStripe(
        for lineNumber: Int,
        atTextViewY y: CGFloat,
        height: CGFloat,
        in textView: NSTextView,
        font: NSFont,
        startsLine: Bool
    ) {
        guard let change = gitMarkers.changes[lineNumber] else { return }
        let rulerPoint = convert(NSPoint(x: 0, y: y), from: textView)
        let stripeHeight = max(height, font.capHeight + 4)
        let x = labelTrailingEdge + Self.changeStripeGap
        switch change {
        case .added, .modified:
            let color = change == .added
                ? tokenTheme.gitAddedColor
                : tokenTheme.gitModifiedColor
            color.setFill()
            NSRect(
                x: x,
                y: rulerPoint.y,
                width: Self.changeStripeWidth,
                height: stripeHeight
            ).fill()
        case .removed, .removedAtEnd:
            guard startsLine else { return }
            tokenTheme.gitDeletedColor.setFill()
            let markerHeight = Self.changeStripeWidth
            let markerY = change == .removed
                ? rulerPoint.y - markerHeight / 2
                : rulerPoint.y + stripeHeight - markerHeight / 2
            nudgedIntoBounds(NSRect(
                x: x - Self.changeStripeGap,
                y: markerY,
                width: Self.changeStripeWidth + Self.changeStripeGap,
                height: markerHeight
            )).fill()
        }
    }

    /// X coordinate where the line-number label ends.
    ///
    /// For an untracked file the stripe width is released and the label keeps its original frame.
    private var labelTrailingEdge: CGFloat {
        let stripeInset = gitMarkers.isTracked ? Self.changeStripeInset : 0
        return 4 + max(0, ruleThickness - Self.horizontalPadding - stripeInset)
    }

    /// Moves an edge marker that crosses the view bounds back inside,
    ///
    /// so deletion markers on the first and last visible lines are not clipped in half.
    private func nudgedIntoBounds(_ rect: NSRect) -> NSRect {
        guard rect.height <= bounds.height else { return rect }
        var nudged = rect
        if nudged.minY < bounds.minY {
            nudged.origin.y = bounds.minY
        } else if nudged.maxY > bounds.maxY {
            nudged.origin.y = bounds.maxY - nudged.height
        }
        return nudged
    }
}
