import AppKit
import CmuxAcpmux

/// The auto-growing message composer with harness and model chips and a send/stop button.
@MainActor
final class AcpmuxComposerView: AcpmuxFlippedView {
    let textView = AcpmuxComposerTextView()
    private let textScrollView = NSScrollView()
    let harnessChip = AcpmuxChipButton()
    let modelChip = AcpmuxChipButton()
    private let actionButton = NSButton()
    private var isWorking = false
    private var theme: AcpmuxChatTheme
    var onSubmit: ((String) -> Void)?
    var onCancelTurn: (() -> Void)?
    var onHeightChange: (() -> Void)?

    static let minTextHeight: CGFloat = 22
    static let maxTextHeight: CGFloat = 180
    private static let chipRowHeight: CGFloat = 26
    private static let padding: CGFloat = 10

    init(theme: AcpmuxChatTheme) {
        self.theme = theme
        super.init(frame: .zero)
        layer?.cornerRadius = 14
        layer?.borderWidth = 1

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = theme.bodyFont
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = String(localized: "acpmuxChat.composer.placeholder", defaultValue: "Message the agent")
        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onCancel = { [weak self] in self?.onCancelTurn?() }
        textView.onHeightChange = { [weak self] in
            self?.updateActionButton()
            self?.onHeightChange?()
        }
        textView.setAccessibilityIdentifier("acpmuxChat.composer")
        textScrollView.documentView = textView
        textScrollView.drawsBackground = false
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.scrollerStyle = .overlay
        addSubview(textScrollView)
        addSubview(harnessChip)
        addSubview(modelChip)

        actionButton.isBordered = false
        actionButton.imageScaling = .scaleProportionallyUpOrDown
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        actionButton.setAccessibilityIdentifier("acpmuxChat.send")
        addSubview(actionButton)
        apply(theme: theme)
    }

    func apply(theme: AcpmuxChatTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.surface.cgColor
        layer?.borderColor = theme.border.cgColor
        textView.textColor = theme.foreground
        textView.insertionPointColor = theme.accent
        textView.placeholderColor = theme.tertiaryText
        textView.typingAttributes = [.font: theme.bodyFont, .foregroundColor: theme.foreground]
        updateActionButton()
    }

    func setWorking(_ working: Bool) {
        guard working != isWorking else { return }
        isWorking = working
        updateActionButton()
    }

    /// The composer height for its current text.
    var preferredHeight: CGFloat {
        let text = min(Self.maxTextHeight, max(Self.minTextHeight, textView.contentHeight))
        return Self.padding + text + Self.chipRowHeight + 4
    }

    /// The text area in this view's coordinates, the morph animation's start frame.
    var textFrame: CGRect { textScrollView.frame }

    override func layout() {
        super.layout()
        let padding = Self.padding
        let textHeight = min(Self.maxTextHeight, max(Self.minTextHeight, textView.contentHeight))
        textScrollView.frame = CGRect(x: padding + 2, y: padding, width: bounds.width - 2 * padding - 4, height: textHeight)
        textView.frame.size.width = textScrollView.contentSize.width
        textView.minSize = NSSize(width: 0, height: textHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let chipY = bounds.height - Self.chipRowHeight + 2
        harnessChip.frame.origin = CGPoint(x: padding, y: chipY)
        modelChip.frame.origin = CGPoint(x: harnessChip.isHidden ? padding : harnessChip.frame.maxX + 6, y: chipY)
        actionButton.frame = CGRect(x: bounds.width - padding - 22, y: bounds.height - Self.chipRowHeight - 1, width: 22, height: 22)
    }

    @objc private func actionPressed() {
        if isWorking && textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onCancelTurn?()
        } else {
            submit()
        }
    }

    /// Submits the current text, as Return does.
    func submitCurrentText() {
        submit()
    }

    private func submit() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSubmit?(text)
    }

    /// Clears the text after a send.
    func clear() {
        textView.string = ""
        textView.didChangeText()
    }

    private func updateActionButton() {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let showsStop = isWorking && empty
        let symbol = showsStop ? "stop.circle.fill" : "arrow.up.circle.fill"
        let description = showsStop
            ? String(localized: "acpmuxChat.composer.stop", defaultValue: "Stop")
            : String(localized: "acpmuxChat.composer.send", defaultValue: "Send")
        actionButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        actionButton.contentTintColor = (empty && !showsStop) ? theme.tertiaryText : theme.accent
        actionButton.toolTip = description
    }
}
