import CmuxFoundation
#if DEBUG
import AppKit

final class FeedTextEditorDebugWindowController: ReleasingWindowController {
    static let shared = FeedTextEditorDebugWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "feed.textEditorDebug.windowTitle", defaultValue: "Feed Text Editor Lab")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.feedTextEditorDebug")
        window.center()
        window.contentView = FeedTextEditorDebugView()
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showManagedWindow()
    }
}

private enum FeedTextEditorDebugVariant: String, CaseIterable {
    case appKitDirectSizeThatFits
    case appKitDirectIntrinsic
    case appKitScrollSizeThatFits
    case appKitScrollMeasured

    var title: String {
        switch self {
        case .appKitDirectSizeThatFits:
            String(localized: "feed.textEditorDebug.variant.appKitDirectSize", defaultValue: "AppKit Direct, sizeThatFits")
        case .appKitDirectIntrinsic:
            String(localized: "feed.textEditorDebug.variant.appKitDirectIntrinsic", defaultValue: "AppKit Direct, intrinsic")
        case .appKitScrollSizeThatFits:
            String(localized: "feed.textEditorDebug.variant.appKitScrollSize", defaultValue: "AppKit ScrollView, sizeThatFits")
        case .appKitScrollMeasured:
            String(localized: "feed.textEditorDebug.variant.appKitScrollMeasured", defaultValue: "AppKit ScrollView, measured")
        }
    }
}

@MainActor
private final class FeedTextEditorDebugView: NSView {
    private static let sampleText = "hello from feed"
    private var cards: [FeedTextEditorDebugCard] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        let title = NSTextField(labelWithString: String(localized: "feed.textEditorDebug.title", defaultValue: "Feed Text Editors"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: String(
            localized: "feed.textEditorDebug.subtitle",
            defaultValue: "Compare autosizing editors with identical input."
        ))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4
        let reset = NSButton(
            title: String(localized: "feed.textEditorDebug.reset", defaultValue: "Reset"),
            target: self,
            action: #selector(reset)
        )
        reset.bezelStyle = .rounded
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleStack, headerSpacer, reset])
        header.orientation = .horizontal
        header.alignment = .top

        let section = NSTextField(labelWithString: String(localized: "feed.textEditorDebug.section.appkit", defaultValue: "AppKit"))
        section.font = .systemFont(ofSize: 12, weight: .semibold)
        section.textColor = .secondaryLabelColor

        let placeholder = String(localized: "feed.textEditorDebug.placeholder", defaultValue: "Type several lines here...")
        cards = FeedTextEditorDebugVariant.allCases.map {
            FeedTextEditorDebugCard(
                variant: $0,
                text: Self.sampleText,
                placeholder: placeholder
            )
        }
        let cardStack = NSStackView(views: cards)
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 14

        let root = NSStackView(views: [header, section, cardStack])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        cardStack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        cards.forEach { $0.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = root
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 760),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 560),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    @objc private func reset() {
        cards.forEach { $0.setText(Self.sampleText) }
    }
}

private enum FeedTextEditorDebugAppKitMode {
    case directSizeThatFits
    case directIntrinsic
    case scrollSizeThatFits
    case scrollMeasured

    init(variant: FeedTextEditorDebugVariant) {
        switch variant {
        case .appKitDirectSizeThatFits: self = .directSizeThatFits
        case .appKitDirectIntrinsic: self = .directIntrinsic
        case .appKitScrollSizeThatFits: self = .scrollSizeThatFits
        case .appKitScrollMeasured: self = .scrollMeasured
        }
    }

    var wrapsInScrollView: Bool {
        switch self {
        case .directSizeThatFits, .directIntrinsic: false
        case .scrollSizeThatFits, .scrollMeasured: true
        }
    }

    var usesSizeThatFits: Bool {
        switch self {
        case .directSizeThatFits, .scrollSizeThatFits: true
        case .directIntrinsic, .scrollMeasured: false
        }
    }

    var reportsHeight: Bool {
        if case .scrollMeasured = self { return true }
        return false
    }

    var usesIntrinsicHeight: Bool {
        if case .directIntrinsic = self { return true }
        return false
    }

    var textInset: NSSize {
        switch self {
        case .directSizeThatFits, .directIntrinsic: NSSize(width: 0, height: 1)
        case .scrollSizeThatFits, .scrollMeasured: NSSize(width: 5, height: 4)
        }
    }
}

@MainActor
private final class FeedTextEditorDebugCard: NSView, NSTextViewDelegate {
    private let mode: FeedTextEditorDebugAppKitMode
    private let editor = FeedTextEditorDebugAppKitHost(frame: .zero)
    private let metricsLabel = NSTextField(labelWithString: "")
    private var editorHeight: NSLayoutConstraint!

    init(variant: FeedTextEditorDebugVariant, text: String, placeholder: String) {
        mode = FeedTextEditorDebugAppKitMode(variant: variant)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        layer?.borderWidth = 1

        let title = NSTextField(labelWithString: variant.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        metricsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        metricsLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, spacer, metricsLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline

        editor.textView.delegate = self
        editor.textView.string = text
        editor.apply(
            mode: mode,
            font: GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold),
            placeholder: placeholder
        )
        editor.onMeasuredHeightChange = { [weak self] height in
            guard let self, self.mode.reportsHeight else { return }
            self.updateEditorHeight(height)
        }
        editor.translatesAutoresizingMaskIntoConstraints = false
        editorHeight = editor.heightAnchor.constraint(equalToConstant: 34)
        editorHeight.priority = mode.usesIntrinsicHeight ? .defaultLow : .required

        let stack = NSStackView(views: [header, editor])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editor.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editorHeight,
        ])
        updateMetrics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if mode.usesSizeThatFits {
            updateEditorHeight(editor.fittingHeight(for: max(editor.bounds.width, 1)))
        }
    }

    func setText(_ text: String) {
        editor.textView.string = text
        editor.refreshMetrics()
        updateMetrics()
    }

    func textDidChange(_ notification: Notification) {
        editor.refreshMetrics()
        updateMetrics()
        if mode.usesSizeThatFits {
            updateEditorHeight(editor.fittingHeight(for: max(editor.bounds.width, 1)))
        }
    }

    private func updateMetrics() {
        let text = editor.textView.string
        let lineCount = Int64(text.filter { $0 == "\n" }.count + 1)
        let charCount = Int64((text as NSString).length)
        metricsLabel.stringValue = String(
            format: String(localized: "feed.textEditorDebug.metrics", defaultValue: "%lld lines · %lld chars"),
            lineCount,
            charCount
        )
    }

    private func updateEditorHeight(_ proposed: CGFloat) {
        let height = max(34, ceil(proposed))
        guard abs(editorHeight.constant - height) > 0.5 else { return }
        editorHeight.constant = height
        needsLayout = true
    }
}

@MainActor
private final class FeedTextEditorDebugAppKitHost: NSView {
    let textView = NSTextView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let placeholderField = NSTextField(labelWithString: "")
    private var mode = FeedTextEditorDebugAppKitMode.directSizeThatFits
    private var currentFont = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
    private var lastMeasuredHeight: CGFloat = 0

    var onMeasuredHeightChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.90).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false

        placeholderField.textColor = .placeholderTextColor
        placeholderField.lineBreakMode = .byTruncatingTail
        addSubview(textView)
        addSubview(placeholderField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        mode.usesIntrinsicHeight
            ? NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight())
            : NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        layoutEditor()
        reportMeasuredHeightIfNeeded()
    }

    func apply(mode: FeedTextEditorDebugAppKitMode, font: NSFont, placeholder: String) {
        self.mode = mode
        currentFont = font
        textView.font = font
        textView.textContainerInset = mode.textInset
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        placeholderField.stringValue = placeholder
        placeholderField.font = font
        installEditorContainerIfNeeded()
        refreshMetrics()
    }

    func refreshMetrics() {
        placeholderField.isHidden = !textView.string.isEmpty
        needsLayout = true
        invalidateIntrinsicContentSize()
        reportMeasuredHeightIfNeeded()
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return minimumHeight() }
        let availableWidth = max(width - mode.textInset.width * 2, 1)
        textContainer.containerSize = NSSize(width: availableWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let lineHeight = ceil(currentFont.ascender - currentFont.descender + currentFont.leading)
        return max(minimumHeight(), ceil(max(lineHeight, usedRect.height) + mode.textInset.height * 2))
    }

    private func fittingHeight() -> CGFloat {
        fittingHeight(for: max(bounds.width, 1))
    }

    private func minimumHeight() -> CGFloat {
        ceil(currentFont.ascender - currentFont.descender + currentFont.leading) + mode.textInset.height * 2
    }

    private func installEditorContainerIfNeeded() {
        if mode.wrapsInScrollView {
            if scrollView.superview == nil {
                textView.removeFromSuperview()
                scrollView.documentView = textView
                addSubview(scrollView, positioned: .below, relativeTo: placeholderField)
            }
        } else if textView.superview !== self {
            scrollView.documentView = nil
            scrollView.removeFromSuperview()
            addSubview(textView, positioned: .below, relativeTo: placeholderField)
        }
    }

    private func layoutEditor() {
        let availableWidth = max(bounds.width, 1)
        let height = fittingHeight(for: availableWidth)
        if mode.wrapsInScrollView {
            scrollView.frame = bounds
            textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: max(height, bounds.height))
        } else {
            textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: height)
        }
        placeholderField.frame = NSRect(
            x: mode.textInset.width,
            y: mode.textInset.height,
            width: max(bounds.width - mode.textInset.width * 2, 1),
            height: minimumHeight()
        )
    }

    private func reportMeasuredHeightIfNeeded() {
        guard mode.reportsHeight else { return }
        let height = fittingHeight()
        guard abs(lastMeasuredHeight - height) > 0.5 else { return }
        lastMeasuredHeight = height
        onMeasuredHeightChange?(height)
    }
}
#endif
