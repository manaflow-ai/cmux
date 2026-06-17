public import AppKit

/// A self-sizing, scrollable multiline message editor used by the feedback
/// composer. Grows its document height with content (with an overlay scroller
/// once it exceeds the visible area) and shows a placeholder while empty.
public final class FeedbackComposerMessageEditorView: NSView {
    private static let font = NSFont.systemFont(ofSize: 12)
    private static let textInset = NSSize(width: 10, height: 10)
    private static let minimumDocumentHeight: CGFloat = {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight + textInset.height * 2
    }()

    public let scrollView = FeedbackComposerMessageScrollView()
    public let textView = NSTextView()
    private let placeholderField = FeedbackComposerPassthroughLabel(labelWithString: "")

    public var placeholder: String = "" {
        didSet {
            placeholderField.stringValue = placeholder
            updatePlaceholderVisibility()
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.focusTextView = textView

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = NSSize(width: 0, height: Self.minimumDocumentHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        addSubview(scrollView)

        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.font = Self.font
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.lineBreakMode = .byWordWrapping
        placeholderField.maximumNumberOfLines = 0
        scrollView.contentView.addSubview(placeholderField)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            placeholderField.topAnchor.constraint(
                equalTo: scrollView.contentView.topAnchor,
                constant: Self.textInset.height
            ),
            placeholderField.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor,
                constant: Self.textInset.width
            ),
            placeholderField.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentView.trailingAnchor,
                constant: -Self.textInset.width
            ),
        ])

        updatePlaceholderVisibility()
    }

    public override func layout() {
        super.layout()
        syncTextViewFrameToContentSize()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func textDidChange(_ notification: Notification) {
        refreshTextLayout(scrollSelection: true)
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = textView.string.isEmpty == false
    }

    public func refreshTextLayout(scrollSelection: Bool = false) {
        updatePlaceholderVisibility()
        needsLayout = true
        layoutSubtreeIfNeeded()
        syncTextViewFrameToContentSize()
        if scrollSelection {
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    private func naturalDocumentHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return Self.minimumDocumentHeight
        }

        let textWidth = max(width - Self.textInset.width * 2, 1)
        textContainer.containerSize = NSSize(
            width: textWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let extraLineHeight: CGFloat
        if layoutManager.extraLineFragmentTextContainer === textContainer {
            extraLineHeight = ceil(layoutManager.extraLineFragmentRect.height)
        } else {
            extraLineHeight = 0
        }
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        let contentHeight = max(lineHeight, ceil(usedRect.height) + extraLineHeight)
        return max(
            Self.minimumDocumentHeight,
            ceil(contentHeight + Self.textInset.height * 2)
        )
    }

    private func syncTextViewFrameToContentSize() {
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        textView.minSize = NSSize(width: 0, height: contentSize.height)
        let naturalHeight = naturalDocumentHeight(for: contentSize.width)
        let targetSize = NSSize(
            width: contentSize.width,
            height: max(naturalHeight, contentSize.height)
        )
        if textView.frame.size != targetSize {
            textView.frame = NSRect(origin: .zero, size: targetSize)
        }
    }
}
