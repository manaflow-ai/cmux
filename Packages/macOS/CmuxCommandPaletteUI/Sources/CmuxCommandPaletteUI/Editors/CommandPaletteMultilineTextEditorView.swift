public import AppKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// AppKit container view hosting the command-palette multiline text editor:
/// a non-bordered `NSScrollView` wrapping a `CommandPaletteMultilineTextView`
/// plus a passthrough placeholder label.
///
/// Owns the layout math that measures the text's natural height, caps it at a
/// caller-supplied maximum, and reports height changes through
/// `onMeasuredHeightChange` so the SwiftUI host can size the editor frame.
public final class CommandPaletteMultilineTextEditorView: NSView {
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let textInset = NSSize(width: 0, height: 2)
    public static let defaultMinimumHeight: CGFloat = {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight * 5 + textInset.height * 2
    }()

    private let scrollView = NSScrollView(frame: .zero)
    public let textView = CommandPaletteMultilineTextView(frame: .zero)
    private let placeholderField = CommandPalettePassthroughLabel(labelWithString: "")
    public var onMeasuredHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat?
    public var maximumHeight: CGFloat = .greatestFiniteMagnitude {
        didSet {
            refreshMetrics()
        }
    }

    public var placeholder: String = "" {
        didSet {
            placeholderField.stringValue = placeholder
            updatePlaceholderVisibility()
        }
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = NSSize(width: 0, height: Self.defaultMinimumHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.font = Self.font
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.lineBreakMode = .byWordWrapping
        placeholderField.maximumNumberOfLines = 0
        addSubview(placeholderField)

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

            placeholderField.topAnchor.constraint(equalTo: topAnchor, constant: Self.textInset.height),
            placeholderField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset.width),
            placeholderField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.textInset.width),
        ])

        updatePlaceholderVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override public func layout() {
        super.layout()
        updateTextViewLayout()
        reportMeasuredHeightIfNeeded()
    }

    public func refreshMetrics() {
        updatePlaceholderVisibility()
        needsLayout = true
        layoutSubtreeIfNeeded()
        reportMeasuredHeightIfNeeded()
    }

    public func focusIfNeeded() {
        guard let window else {
#if DEBUG
            logDebugEvent("palette.wsDescription.editor.focusIfNeeded window=nil")
#endif
            return
        }
        guard window.firstResponder !== textView else {
#if DEBUG
            logDebugEvent(
                "palette.wsDescription.editor.focusIfNeeded alreadyFocused window={\((window).commandPaletteWindowDebugSummary)}"
            )
#endif
            return
        }
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.focusIfNeeded attempt window={\((window).commandPaletteWindowDebugSummary)} " +
            "frBefore=\((window.firstResponder).commandPaletteResponderDebugSummary)"
        )
#endif
        let didFocus = window.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
#if DEBUG
        logDebugEvent(
            "palette.wsDescription.editor.focusIfNeeded result didFocus=\(didFocus ? 1 : 0) " +
            "window={\((window).commandPaletteWindowDebugSummary)} " +
            "frAfter=\((window.firstResponder).commandPaletteResponderDebugSummary)"
        )
#endif
    }

    private func cappedMaximumHeight() -> CGFloat {
        max(Self.defaultMinimumHeight, maximumHeight)
    }

    private func naturalHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return Self.defaultMinimumHeight
        }
        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        let contentHeight = max(lineHeight, ceil(usedRect.height))
        return max(
            Self.defaultMinimumHeight,
            ceil(contentHeight + Self.textInset.height * 2)
        )
    }

    private func updateTextViewLayout() {
        let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
        let naturalHeight = naturalHeight(for: availableWidth)
        let measuredHeight = min(cappedMaximumHeight(), naturalHeight)
        let documentHeight = max(naturalHeight, measuredHeight)
        textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: documentHeight)
    }

    private func fittingHeight() -> CGFloat {
        let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
        return min(cappedMaximumHeight(), naturalHeight(for: availableWidth))
    }

    private func reportMeasuredHeightIfNeeded() {
        let height = fittingHeight()
        guard lastReportedHeight == nil || abs((lastReportedHeight ?? height) - height) > 0.5 else { return }
        lastReportedHeight = height
        onMeasuredHeightChange?(height)
    }

    @objc
    private func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
        reportMeasuredHeightIfNeeded()
#if DEBUG
        let newlineCount = textView.string.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        logDebugEvent(
            "palette.wsDescription.editor.textDidChange len=\((textView.string as NSString).length) " +
            "newlines=\(newlineCount)"
        )
#endif
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = textView.string.isEmpty == false
    }
}
