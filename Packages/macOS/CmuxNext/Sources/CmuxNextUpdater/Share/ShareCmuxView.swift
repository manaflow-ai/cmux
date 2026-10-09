public import AppKit
import CmuxNextDesign

/// "Share cmux" (cx-7py7): a centered modal in the cmux dialog style
/// (theme grays, no accent color): a title, one short line, an editable
/// message that carries the plain public download link, a Copy Link button
/// that copies the message as shown and turns into "Copied", and an x.
/// Escape closes it too. No referral or gift tracking: the link is the
/// public download page. The App presents it (`app.shareCmux`).
@MainActor
public final class ShareCmuxView: NSView {
    /// The public download page (the same link the team invite email uses).
    public static let downloadURL = URL(string: "https://cmux.com/download")!  // crash-allow: a constant valid URL

    /// The prefilled message: one localized sentence, a blank line, the link.
    public static var defaultMessage: String { "\(ShareCmuxStrings.message)\n\n\(downloadURL.absoluteString)" }

    /// Copy Link's default write: the message as plain text on the general pasteboard.
    public static func writeToGeneralPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The x or Escape (the presenter dismisses the overlay).
    public var onClose: (() -> Void)?
    let copyButton: CmuxDialogButtonView
    let closeButton: NSButton
    let messageView = ShareCmuxMessageTextView()
    private let titleLabel = NSTextField(wrappingLabelWithString: ShareCmuxStrings.title)
    private let bodyLabel = NSTextField(wrappingLabelWithString: ShareCmuxStrings.body)
    private let messageScroll = NSScrollView()
    private let stack = NSStackView()
    /// The modal's material, below the lines (like the tip card, cx-367y).
    let surface: OverlaySurfaceView
    private let writeToPasteboard: @MainActor (String) -> Void

    /// `writeToPasteboard` puts the copied message on the general pasteboard
    /// (tests record it instead).
    public init(writeToPasteboard: @escaping @MainActor (String) -> Void = ShareCmuxView.writeToGeneralPasteboard) {
        self.writeToPasteboard = writeToPasteboard
        surface = OverlaySurfaceView(interactive: true)
        copyButton = CmuxDialogButtonView(CmuxDialogButton(id: "copy-link", title: ShareCmuxStrings.copyLink, role: .default),
                                          target: nil, action: #selector(ShareCmuxView.copyMessage))
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: ShareCmuxStrings.close) ?? NSImage(),
                               target: nil, action: nil)
        super.init(frame: .zero)
        copyButton.target = self
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel(ShareCmuxStrings.title)
        setAccessibilityModal(true)
        identifier = NSUserInterfaceItemIdentifier("cmux.shareCmux")
        setFrameSize(fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The message as shown (edits included).
    public var messageText: String {
        get { messageView.string }
        set {
            messageView.string = newValue
            copyButton.retitle(ShareCmuxStrings.copyLink)
        }
    }

    /// Copy Link: the message as shown goes to the pasteboard; the button
    /// says "Copied" until the message changes.
    @objc public func copyMessage() {
        writeToPasteboard(messageText)
        copyButton.retitle(ShareCmuxStrings.copied)
    }

    @objc private func closePressed() { onClose?() }

    /// Gives the keyboard to Copy Link (the presenter, once the modal shows).
    public func focusCopyLink() {
        window?.makeFirstResponder(copyButton)
    }

    public override func cancelOperation(_ sender: Any?) { onClose?() }

    /// Return copies while Copy Link has the keyboard (Space presses it too);
    /// in the message, Return types a line break.
    public override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), window?.firstResponder === copyButton {
            copyMessage()
        } else {
            super.keyDown(with: event)
        }
    }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: Layout

    static var width: CGFloat { 380 * Typography.userScale }

    private func build() {
        let padding = Metrics.space5, contentWidth = Self.width - 2 * padding
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Typography.title
        titleLabel.preferredMaxLayoutWidth = contentWidth - 20 - 2 * Metrics.space2
        bodyLabel.font = Typography.body
        bodyLabel.preferredMaxLayoutWidth = contentWidth
        for label in [titleLabel, bodyLabel] { label.isSelectable = false }
        bodyLabel.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.setAccessibilityLabel(ShareCmuxStrings.close)
        closeButton.toolTip = ShareCmuxStrings.close
        closeButton.identifier = NSUserInterfaceItemIdentifier("cmux.shareCmux.close")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let header = NSStackView(views: [titleLabel, NSView(), closeButton])
        header.orientation = .horizontal
        header.spacing = Metrics.space2
        header.alignment = .top
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.font = Typography.body
        messageView.drawsBackground = false
        messageView.textContainerInset = NSSize(width: Metrics.space2, height: Metrics.space2)
        messageView.isVerticallyResizable = true
        messageView.isHorizontallyResizable = false
        messageView.minSize = NSSize(width: 0, height: 96 * Typography.userScale)
        messageView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        messageView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 96 * Typography.userScale)
        messageView.autoresizingMask = [.width]
        messageView.textContainer?.widthTracksTextView = true
        messageView.string = Self.defaultMessage
        messageView.setAccessibilityLabel(ShareCmuxStrings.messageLabel)
        messageView.identifier = NSUserInterfaceItemIdentifier("cmux.shareCmux.message")
        messageView.onEdit = { [weak self] in self?.copyButton.retitle(ShareCmuxStrings.copyLink) }
        messageView.onCancel = { [weak self] in self?.onClose?() }
        messageView.onTab = { [weak self] backward in
            guard let self else { return }
            self.window?.makeFirstResponder(backward ? self.closeButton : self.copyButton)
        }
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.autohidesScrollers = true
        messageScroll.drawsBackground = false
        messageScroll.borderType = .noBorder
        messageScroll.wantsLayer = true
        messageScroll.layer?.cornerRadius = 7
        messageScroll.layer?.cornerCurve = .continuous
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        messageScroll.heightAnchor.constraint(equalToConstant: 96 * Typography.userScale).isActive = true

        copyButton.identifier = NSUserInterfaceItemIdentifier("cmux.shareCmux.copyLink")
        copyButton.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        [header, bodyLabel, messageScroll, copyButton].forEach(stack.addArrangedSubview)
        // The lines sit in a sibling above the material, not inside the glass's own view (nxdog75).
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        addSubview(stack)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            bodyLabel.textColor = Palette.textSecondary
            messageView.textColor = Palette.textPrimary
            messageView.insertionPointColor = Palette.textPrimary
            messageScroll.layer?.backgroundColor = Palette.hoverFill.cgColor
            closeButton.contentTintColor = Palette.textSecondary
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        surface.applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    // MARK: Tests

    /// The title and the line, as shown.
    var shownText: [String] { [titleLabel.stringValue, bodyLabel.stringValue] }
}

/// The message box: plain text; Escape closes the modal instead of
/// completing a word; Tab and Shift-Tab leave it (the overlay's Tab cycle
/// holds only controls); every edit puts "Copy Link" back.
final class ShareCmuxMessageTextView: NSTextView {
    var onEdit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Tab (false) or Shift-Tab (true).
    var onTab: ((Bool) -> Void)?

    override func insertTab(_ sender: Any?) { onTab?(false) }
    override func insertBacktab(_ sender: Any?) { onTab?(true) }

    override func didChangeText() {
        super.didChangeText()
        onEdit?()
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
