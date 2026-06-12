import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

private final class FeedInlinePassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FeedInlineNativeTextView: NSTextView, FeedKeyboardFocusResponder {
    private static weak var activeEditor: FeedInlineNativeTextView?

    var onActivate: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSubmit: (() -> Void)?

    static func blurActiveEditor() {
        guard let activeEditor else { return }
        guard let window = activeEditor.window else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
        guard window.firstResponder === activeEditor else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
#if DEBUG
        dlog("feed.editor.blurActive fr=\(feedDebugResponderSummary(window.firstResponder))")
#endif
        window.makeFirstResponder(nil)
    }

    override func mouseDown(with event: NSEvent) {
#if DEBUG
        dlog("feed.editor.mouseDown frBefore=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        onActivate?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            dlog("feed.editor.escape fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shouldSubmit = (event.keyCode == 36 || event.keyCode == 76)
            && normalizedFlags.intersection([.shift, .option, .command, .control]).isEmpty
        if shouldSubmit, !hasMarkedText(), let onSubmit {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            Self.activeEditor = self
            onActivate?()
        }
#if DEBUG
        dlog("feed.editor.become result=\(didBecomeFirstResponder ? 1 : 0) fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder, Self.activeEditor === self {
            Self.activeEditor = nil
        }
#if DEBUG
        dlog("feed.editor.resign result=\(didResignFirstResponder ? 1 : 0) fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        return didResignFirstResponder
    }
}

final class FeedInlineTextEditorView: NSView {
    private static let textInset = NSSize(width: 0, height: 1)

    let textView = FeedInlineNativeTextView(frame: .zero)
    private let placeholderField = FeedInlinePassthroughLabel(labelWithString: "")
    private var currentFont = NSFont.systemFont(ofSize: 11)

    static func minimumHeight(for font: NSFont) -> CGFloat {
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

    override var isFlipped: Bool { true }

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

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight())
    }

    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    override func layout() {
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

struct FeedInlineTextField: NSViewRepresentable {
    @Binding var text: String

    let focusRequest: Int?
    let placeholder: String
    let isEnabled: Bool
    let font: NSFont
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onSubmit: (() -> Void)?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedInlineTextField
        var isProgrammaticMutation = false
        weak var view: FeedInlineTextEditorView?
        var lastAppliedFocusRequest: Int?

        init(parent: FeedInlineTextField) {
            self.parent = parent
            self.lastAppliedFocusRequest = parent.focusRequest
        }

        func activateField() {
#if DEBUG
            dlog("feed.editor.activateField")
#endif
            parent.onFocus()
        }

        func blurField() {
            guard let view, let window = view.window, window.firstResponder === view.textView else {
                return
            }
#if DEBUG
            dlog("feed.editor.blurField frBefore=\(feedDebugResponderSummary(window.firstResponder))")
#endif
            Task { @MainActor in
                if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                    mode: .feed,
                    focusFirstItem: false,
                    preferredWindow: window
                ) != true {
                    window.makeFirstResponder(nil)
                }
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            activateField()
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            view?.refreshMetrics()
        }

        func textDidEndEditing(_ notification: Notification) {
            if !isProgrammaticMutation, let textView = notification.object as? NSTextView {
                parent.text = textView.string
            }
            guard let window = view?.window else {
                parent.onBlur()
                return
            }
            let responder = window.firstResponder
            if !(responder is FeedKeyboardFocusView) && !(responder is FeedInlineNativeTextView) {
                parent.onBlur()
            }
        }

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FeedInlineTextEditorView {
        let view = FeedInlineTextEditorView(frame: .zero)
        view.textView.delegate = context.coordinator
        view.textView.string = text
        view.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        view.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        view.textView.onSubmit = onSubmit
        configure(view)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: FeedInlineTextEditorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.view = nsView
        nsView.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        nsView.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        nsView.textView.onSubmit = onSubmit
        configure(nsView)

        if nsView.textView.string != text, !nsView.textView.hasMarkedText() {
            context.coordinator.isProgrammaticMutation = true
            nsView.textView.string = text
            context.coordinator.isProgrammaticMutation = false
            nsView.refreshMetrics()
        }

        guard let window = nsView.window else { return }
        let isFirstResponder = window.firstResponder === nsView.textView
        if let focusRequest,
           focusRequest != context.coordinator.lastAppliedFocusRequest {
            context.coordinator.lastAppliedFocusRequest = focusRequest
            if isEnabled {
                nsView.focusIfNeeded()
            } else if isFirstResponder {
                moveFocusToFeedHost(in: window)
            }
        } else if focusRequest == nil {
            context.coordinator.lastAppliedFocusRequest = nil
            if !isEnabled, isFirstResponder {
                moveFocusToFeedHost(in: window)
            }
        } else if !isEnabled, isFirstResponder {
            moveFocusToFeedHost(in: window)
        }
    }

    private func moveFocusToFeedHost(in window: NSWindow) {
        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: .feed,
            focusFirstItem: false,
            preferredWindow: window
        ) == true {
            return
        }
        window.makeFirstResponder(nil)
    }

    private func configure(_ view: FeedInlineTextEditorView) {
        view.placeholder = placeholder
        view.apply(font: font, isEnabled: isEnabled)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: FeedInlineTextEditorView,
        context: Context
    ) -> CGSize? {
        nil
    }

    static func dismantleNSView(_ nsView: FeedInlineTextEditorView, coordinator: Coordinator) {
        nsView.textView.delegate = nil
        nsView.textView.onActivate = nil
        nsView.textView.onEscape = nil
        nsView.textView.onSubmit = nil
    }
}

