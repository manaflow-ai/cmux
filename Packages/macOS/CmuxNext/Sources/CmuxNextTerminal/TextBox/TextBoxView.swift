package import AppKit
package import CmuxNextDesign
package import CmuxNextIcons
package import Observation

/// The TextBox strip under a terminal: the submit action button (click or Shift-Tab changes it),
/// the multi-line editor with its placeholder, and Add Files. It grows with its lines up to
/// ``maxLines``, then scrolls. Shows what its ``TextBoxModel`` holds.
package final class TextBoxView: NSView, NSTextViewDelegate {
    package static let maxLines = 10
    private static let inset: CGFloat = 8
    private static let buttonSide: CGFloat = 24

    package let model: TextBoxModel
    package let textView = TextBoxTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: TextBoxStrings.placeholder)
    private let actionButton = NSButton()
    private let attachButton = NSButton()
    private let separator = NSBox()
    /// Runs a registry action through the App (the cycle and attach buttons).
    package var perform: @MainActor (TextBoxCommand) -> Void = { _ in }

    package init(model: TextBoxModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 36))
        wantsLayer = true
        separator.boxType = .separator
        addSubview(separator)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = self
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        // Thin, shown only while scrolling (SCROLLBARS-THIN).
        SystemScrollers.follow(scroll)
        addSubview(scroll)

        placeholder.textColor = .placeholderTextColor
        placeholder.font = textView.font
        addSubview(placeholder)

        for button in [actionButton, attachButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            addSubview(button)
        }
        actionButton.action = #selector(cycle(_:))
        actionButton.themedToolTip = TextBoxStrings.cycleHelp
        attachButton.action = #selector(attach(_:))
        attachButton.image = NSImage.icon(.composerAttach, size: 14)
        attachButton.setAccessibilityLabel(TextBoxStrings.addFiles)
        follow()
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the model's text, action and visibility now and on every change.
    private func follow() {
        let (text, action, visible) = withObservationTracking {
            (model.text, model.action, model.isVisible)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        if textView.string != text { textView.replaceText(text) }
        actionButton.image = NSImage.icon(symbol: action.symbol, size: 14)
        actionButton.setAccessibilityLabel(action.title)
        actionButton.themedToolTip = "\(action.title): \(TextBoxStrings.cycleHelp)"
        if isHidden == visible { isHidden = !visible }
        refreshHeight()
    }

    /// Takes the editor's text into the model (the editor is what the user typed in).
    package func commitText() {
        if model.text != textView.string { model.text = textView.string }
    }

    package func textDidChange(_ notification: Notification) {
        commitText()
        refreshHeight()
    }

    private func refreshHeight() {
        placeholder.isHidden = !textView.string.isEmpty
        superview?.needsLayout = true
        needsLayout = true
    }

    private var lineHeight: CGFloat {
        let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ceil(textView.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize * 1.2)
    }

    /// The editor's height: its lines, at least one and at most ``maxLines``.
    private var editorHeight: CGFloat {
        var used = lineHeight
        if let manager = textView.layoutManager, let container = textView.textContainer {
            manager.ensureLayout(for: container)
            used = manager.usedRect(for: container).height
        }
        return min(max(lineHeight, ceil(used)), lineHeight * CGFloat(Self.maxLines))
    }

    package override var fittingSize: NSSize {
        NSSize(width: frame.width, height: editorHeight + Self.inset * 2)
    }

    package override func layout() {
        super.layout()
        let side = Self.buttonSide, inset = Self.inset
        separator.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        actionButton.frame = CGRect(x: inset, y: inset + (lineHeight - side) / 2, width: side, height: side).integral
        attachButton.frame = CGRect(x: bounds.width - inset - side, y: actionButton.frame.minY, width: side, height: side)
        let editor = CGRect(x: actionButton.frame.maxX + 6, y: inset, width: max(0, attachButton.frame.minX - 6 - actionButton.frame.maxX - 6),
                            height: max(0, bounds.height - inset * 2))
        if scroll.frame != editor { scroll.frame = editor }
        textView.minSize = NSSize(width: 0, height: editor.height)
        textView.maxSize = NSSize(width: editor.width, height: .greatestFiniteMagnitude)
        if textView.frame.width != editor.width { textView.setFrameSize(NSSize(width: editor.width, height: max(editor.height, textView.frame.height))) }
        placeholder.frame = CGRect(x: editor.minX, y: editor.maxY - lineHeight, width: editor.width, height: lineHeight)
    }

    package override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor  // glass-opaque-allow: an editable text box's field fill (85%)
    }

    package override var wantsUpdateLayer: Bool { true }

    @objc private func cycle(_ sender: Any?) { perform(.cycleSubmitAction) }

    @objc private func attach(_ sender: Any?) { perform(.attachFile) }
}
