import AppKit

/// A read-only alert details view whose viewport is capped to the visible
/// screen while its complete text remains scrollable and selectable.
@MainActor
final class CmuxAlertScrollableDetailsView: NSScrollView {
    static let accessibilityIdentifier = "CmuxAlertScrollableDetails"
    static let maximumVisibleFrameHeightFraction: CGFloat = 0.4

    private(set) var contentHeight: CGFloat = 0
    let maximumHeight: CGFloat

    var isContentHeightCapped: Bool {
        contentHeight > frame.height
    }

    static func maximumHeight(for visibleFrame: NSRect) -> CGFloat {
        max(44, floor(visibleFrame.height * maximumVisibleFrameHeightFraction))
    }

    init(text: String, visibleFrame: NSRect) {
        let width = min(420, max(260, floor(visibleFrame.width * 0.55)))
        maximumHeight = Self.maximumHeight(for: visibleFrame)

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: maximumHeight))

        borderType = .bezelBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        hasHorizontalScroller = false
        hasVerticalScroller = true
        autohidesScrollers = true
        setAccessibilityIdentifier(Self.accessibilityIdentifier)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: 1))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            textView.sizeToFit()
            layoutManager.ensureLayout(for: textContainer)
            contentHeight = ceil(
                layoutManager.usedRect(for: textContainer).height
                    + textView.textContainerInset.height * 2
            )
        }

        let viewportHeight = min(max(44, contentHeight), maximumHeight)
        setFrameSize(NSSize(width: width, height: viewportHeight))
        textView.setFrameSize(NSSize(width: contentSize.width, height: max(contentHeight, viewportHeight)))
        hasVerticalScroller = contentHeight > viewportHeight
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        frame.size
    }
}
