#if canImport(UIKit)
import UIKit

/// Messages-style edit: the transcript blurs, the message becomes an editable
/// field where its bubble was (kept above the keyboard), with a grey X on the
/// left that reverts and a blue checkmark on the right that saves. The
/// composer and its draft are left alone.
final class MessageEditOverlay: UIView, UITextViewDelegate {
    let textView = UITextView()
    private let blur = UIVisualEffectView(effect: nil)
    private let field = UIView()
    private let cancelButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let original: String
    private var heightConstraint: NSLayoutConstraint?
    private var blurAnimator: UIViewPropertyAnimator?
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?

    static let buttonSize: CGFloat = 32
    static let maxFieldHeight: CGFloat = 200

    init(text: String) {
        original = text
        super.init(frame: .zero)
        accessibilityIdentifier = "conversation.edit"
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.backgroundColor = .systemBackground
        field.layer.cornerRadius = ConversationTheme.bubbleCornerRadius
        field.layer.cornerCurve = .continuous
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.separator.cgColor
        addSubview(field)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = ConversationTheme.bodyFont
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(
            top: ConversationTheme.bubbleVerticalPadding, left: ConversationTheme.bubbleHorizontalPadding - 5,
            bottom: ConversationTheme.bubbleVerticalPadding, right: ConversationTheme.bubbleHorizontalPadding - 5
        )
        textView.text = text
        textView.delegate = self
        textView.accessibilityIdentifier = "conversation.edit.text"
        field.addSubview(textView)

        let symbols = UIImage.SymbolConfiguration(pointSize: Self.buttonSize, weight: .regular)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: symbols), for: .normal)
        cancelButton.tintColor = .systemGray2
        cancelButton.accessibilityLabel = String(localized: "conversation.edit.cancel", defaultValue: "Cancel Edit", bundle: .module)
        cancelButton.accessibilityIdentifier = "conversation.edit.cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        addSubview(cancelButton)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setImage(UIImage(systemName: "checkmark.circle.fill", withConfiguration: symbols), for: .normal)
        saveButton.tintColor = .systemBlue
        saveButton.accessibilityLabel = String(localized: "conversation.composer.saveEdit", defaultValue: "Save Edit", bundle: .module)
        saveButton.accessibilityIdentifier = "conversation.edit.save"
        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)
        addSubview(saveButton)
        updateSaveEnabled()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Adds the overlay over `host`, with the field where the bubble is
    /// (`sourceFrame`, in host coordinates) and never under the keyboard or
    /// above `topInset`.
    func install(in host: UIView, sourceFrame: CGRect, topInset: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        let gap: CGFloat = 8
        let side = ConversationTheme.composerSideInset - 12
        let height = textView.heightAnchor.constraint(equalToConstant: fieldHeight(width: host.bounds.width - 2 * (side + Self.buttonSize + gap)))
        heightConstraint = height
        let atBubble = field.bottomAnchor.constraint(equalTo: topAnchor, constant: sourceFrame.maxY)
        atBubble.priority = .defaultHigh
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side),
            cancelButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            cancelButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            field.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: gap),
            field.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -gap),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side),
            saveButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            saveButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            // Buttons sit on the field's last line, like the composer's send button.
            cancelButton.centerYAnchor.constraint(equalTo: field.bottomAnchor, constant: -22),
            saveButton.centerYAnchor.constraint(equalTo: field.bottomAnchor, constant: -22),
            textView.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            textView.topAnchor.constraint(equalTo: field.topAnchor),
            textView.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            height,
            atBubble,
            field.bottomAnchor.constraint(lessThanOrEqualTo: host.keyboardLayoutGuide.topAnchor, constant: -12),
            field.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: topInset + 8),
        ])
        host.layoutIfNeeded()
        field.alpha = 0
        cancelButton.alpha = 0
        saveButton.alpha = 0
        // The long-press menu's partial blur: the transcript stays faintly legible.
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
            self.blur.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = 0.28
        blurAnimator = animator
        blur.alpha = 0
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut]) {
            self.blur.alpha = 1
            self.field.alpha = 1
            self.cancelButton.alpha = 1
            self.saveButton.alpha = 1
        }
        textView.becomeFirstResponder()
        let end = textView.endOfDocument
        textView.selectedTextRange = textView.textRange(from: end, to: end)
    }

    func dismiss(completion: @escaping () -> Void) {
        textView.resignFirstResponder()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
            self.blur.alpha = 0
            self.field.alpha = 0
            self.cancelButton.alpha = 0
            self.saveButton.alpha = 0
        } completion: { _ in
            self.blurAnimator?.stopAnimation(true)
            self.blurAnimator = nil
            self.removeFromSuperview()
            completion()
        }
    }

    /// The checkmark's action, for scripted runs.
    func saveFromLab() { save() }

    private func save() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unchanged or emptied message saves nothing; the X is the only revert.
        guard !text.isEmpty else { return }
        if text == original.trimmingCharacters(in: .whitespacesAndNewlines) {
            onCancel?()
        } else {
            onSave?(text)
        }
    }

    private func fieldHeight(width: CGFloat) -> CGFloat {
        let fitting = textView.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude)).height
        return min(Self.maxFieldHeight, max(ConversationTheme.composerMinHeight, fitting))
    }

    private func updateSaveEnabled() {
        saveButton.isEnabled = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func textViewDidChange(_ textView: UITextView) {
        updateSaveEnabled()
        let height = fieldHeight(width: textView.bounds.width)
        textView.isScrollEnabled = height >= Self.maxFieldHeight
        if heightConstraint?.constant != height {
            heightConstraint?.constant = height
            layoutIfNeeded()
        }
    }
}
#endif
