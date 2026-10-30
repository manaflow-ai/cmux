#if os(iOS)
import UIKit

/// A composer's growing text view that follows a `ComposerReturnPolicy`:
/// hardware Return, Shift-Return and Option-Return are key commands (each
/// decided by the policy), and the on-screen keyboard's Return reaches the
/// delegate as a "\n" insertion, which `returnShouldInsert(_:)` decides.
/// While text is being composed (marked text, as in Japanese or Chinese
/// input), Return belongs to the input method and the commands step aside.
/// Shows a placeholder while empty.
open class ComposerReturnTextView: UITextView {
    public var returnPolicy: ComposerReturnPolicy
    /// Called when Return should send the draft.
    public var onSend: (() -> Void)?
    /// Whether the edit menu offers New Line (for a composer whose Return sends).
    public var offersNewLineMenuItem = false
    /// Set by a composer that takes attachments: the edit menu's Paste and
    /// Command-V hand it a copied image or file instead of pasting text (a
    /// plain text view offers no Paste for an image at all). The paste is the
    /// person's own action, so reading the pasteboard then asks nothing.
    public var onPasteAttachments: (() -> Void)?

    private let placeholderLabel = UILabel()
    /// Set while this view inserts its own line break, so the delegate's
    /// Return check lets it through.
    public private(set) var insertingLineBreak = false

    public init(policy: ComposerReturnPolicy) {
        returnPolicy = policy
        super.init(frame: .zero, textContainer: nil)
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .tertiaryLabel
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var placeholder: String = "" {
        didSet {
            placeholderLabel.text = placeholder
            updatePlaceholder()
        }
    }

    override open var text: String! {
        didSet { updatePlaceholder() }
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width - textContainerInset.left - textContainerInset.right)
        let size = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(x: textContainerInset.left + textContainer.lineFragmentPadding, y: textContainerInset.top,
                                        width: width, height: size.height)
    }

    /// Follows a Dynamic Type change.
    public func refreshPlaceholderFont() {
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        setNeedsLayout()
    }

    public func updatePlaceholder() {
        placeholderLabel.isHidden = !(text ?? "").isEmpty
        accessibilityLabel = placeholder
    }

    // MARK: Return

    /// Asked by the delegate for a "\n" replacement (the on-screen keyboard's
    /// Return, or a hardware Return no key command took): true inserts it,
    /// false means it sent (or was refused).
    public func returnShouldInsert(_ replacement: String) -> Bool {
        guard replacement == "\n", !insertingLineBreak else { return true }
        switch returnPolicy.action(hardware: false) {
        case .newline:
            return true
        case .send:
            onSend?()
            return false
        }
    }

    /// Inserts a line break at the selection (Shift-Return, New Line).
    public func insertLineBreak() {
        insertingLineBreak = true
        defer { insertingLineBreak = false }
        insertText("\n")
        scrollRangeToVisible(selectedRange)
    }

    @objc private func hardwareReturn() { perform(returnPolicy.action(hardware: true)) }
    @objc private func hardwareShiftReturn() { perform(returnPolicy.action(hardware: true, shift: true)) }
    @objc private func hardwareOptionReturn() { perform(returnPolicy.action(hardware: true, option: true)) }

    private func perform(_ action: ComposerReturnAction) {
        switch action {
        case .newline: insertLineBreak()
        case .send: onSend?()
        }
    }

    override open var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(hardwareReturn)),
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(hardwareShiftReturn)),
            UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(hardwareOptionReturn)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    override open func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(hardwareReturn), #selector(hardwareShiftReturn), #selector(hardwareOptionReturn):
            // Composing text: Return commits the candidate (the input method's).
            return isEditable && markedTextRange == nil
        case #selector(paste(_:)) where pastesAttachments:
            return isEditable
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    // MARK: Paste

    /// An image or a copied file leads the pasteboard, for a composer that
    /// takes attachments (`composerPastesAttachments`).
    private var pastesAttachments: Bool {
        onPasteAttachments != nil && UIPasteboard.general.composerPastesAttachments
    }

    override open func paste(_ sender: Any?) {
        if pastesAttachments, let onPasteAttachments {
            onPasteAttachments()
        } else {
            super.paste(sender)
        }
    }

    override open func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard offersNewLineMenuItem, isEditable else { return }
        let newLine = UIAction(title: String(localized: "New Line"), image: UIImage(systemName: "return")) { [weak self] _ in
            self?.insertLineBreak()
        }
        builder.insertChild(UIMenu(options: .displayInline, children: [newLine]), atStartOfMenu: .standardEdit)
    }
}
#endif
