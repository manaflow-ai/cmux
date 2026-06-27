public import AppKit

/// Self-sizing AppKit container for the feed inline editor.
///
/// Hosts a ``FeedInlineNativeTextView`` plus a passthrough placeholder label,
/// keeps the text view's frame and the view's intrinsic height in sync with the
/// wrapped content, and exposes the minimum single-line height used by the
/// SwiftUI layout that frames the editor.
public final class FeedInlineTextEditorView: NSView {
    private static let textInset = NSSize(width: 0, height: 1)

    let textView = FeedInlineNativeTextView(frame: .zero)
    private let placeholderField = FeedInlinePassthroughLabel(labelWithString: "")
    private var currentFont = NSFont.systemFont(ofSize: 11)

    /// Minimum height of a single line of `font`, including the editor's text
    /// inset. Used by the SwiftUI host to bound the editor's frame.
    public static func minimumHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + textInset.height * 2
    }

    var placeholder: String = "" {
        didSet {
            guard placeholder != oldValue else { return }
            placeholderField.stringValue = placeholder
            updatePlaceholderVisibility()
        }
    }

    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            textView.isEditable = isEnabled
            textView.isSelectable = isEnabled
            textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor
            textView.insertionPointColor = .controlAccentColor
        }
    }

    override public var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        addSubview(textView)

        placeholderField.textColor = .placeholderTextColor
        placeholderField.lineBreakMode = .byWordWrapping
        placeholderField.maximumNumberOfLines = 0
        addSubview(placeholderField)

        apply(font: currentFont, isEnabled: true)
        updatePlaceholderVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight())
    }

    override public func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    override public func layout() {
        super.layout()
        let availableWidth = max(bounds.width, 1)
        let height = fittingHeight(for: availableWidth)
        textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: height)
        placeholderField.frame = NSRect(
            x: Self.textInset.width,
            y: Self.textInset.height,
            width: max(bounds.width - Self.textInset.width * 2, 1),
            height: Self.minimumHeight(for: currentFont)
        )
    }

    func apply(font: NSFont, isEnabled: Bool) {
        let fontChanged = currentFont != font || textView.font != font || placeholderField.font != font
        let enabledChanged = self.isEnabled != isEnabled

        if fontChanged {
            currentFont = font
            textView.font = font
            placeholderField.font = font
            textView.textColor = self.isEnabled ? .labelColor : .disabledControlTextColor
            textView.insertionPointColor = .controlAccentColor
        }
        if enabledChanged {
            self.isEnabled = isEnabled
        }
        if fontChanged || enabledChanged {
            refreshMetrics()
        }
    }

    func refreshMetrics() {
        updatePlaceholderVisibility()
        needsLayout = true
        invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
    }

    func focusIfNeeded() {
        guard let window, window.firstResponder !== textView else { return }
        window.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return Self.minimumHeight(for: currentFont)
        }
        let availableWidth = max(width - Self.textInset.width * 2, 1)
        textContainer.containerSize = NSSize(
            width: availableWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let extraLineHeight = layoutManager.extraLineFragmentTextContainer == textContainer
            ? layoutManager.extraLineFragmentRect.height
            : 0
        let lineHeight = ceil(currentFont.ascender - currentFont.descender + currentFont.leading)
        let contentHeight = max(lineHeight, ceil(usedRect.height + extraLineHeight))
        return max(
            Self.minimumHeight(for: currentFont),
            ceil(contentHeight + Self.textInset.height * 2)
        )
    }

    private func updateTextViewLayout() {
        let availableWidth = max(bounds.width, 1)
        let height = fittingHeight(for: availableWidth)
        textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: height)
    }

    private func fittingHeight() -> CGFloat {
        guard bounds.width > 1 else {
            return Self.minimumHeight(for: currentFont)
        }
        let availableWidth = max(bounds.width, 1)
        return fittingHeight(for: availableWidth)
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = !textView.string.isEmpty
    }
}
