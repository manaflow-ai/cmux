#if canImport(UIKit)
import UIKit

/// The composer bar. It IS the keyboard's `inputAccessoryView` (vended by the
/// view controller), so the responder infrastructure moves it with the keyboard
/// frame for frame, including through an interactive swipe-to-dismiss, with no
/// per-frame code on our side. Height is driven by Auto Layout + an
/// `intrinsicContentSize` override so the growing text view enlarges the
/// keyboard region correctly.
final class ComposerBar: UIInputView {
    private let textView = GrowingTextView()
    private let sendButton = UIButton(type: .system)
    private let placeholderLabel = UILabel()
    private let separator = UIView()

    /// Invoked with the trimmed prompt when the user taps send.
    var onSend: ((String) -> Void)?
    /// Invoked whenever the bar's height changes (text grew/shrank) so the
    /// owner can refresh the accessory's intrinsic size.
    var onHeightChange: (() -> Void)?

    private let verticalPadding: CGFloat = 8
    private var resolvedTextHeight: CGFloat = 36

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        autoresizingMask = .flexibleHeight
        accessibilityIdentifier = "ChatLabComposer"
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The text view that becomes first responder to raise the keyboard.
    var editor: UITextView { textView }

    /// Resolved bar height; exposed for the measurement probe.
    var resolvedHeight: CGFloat { resolvedTextHeight + verticalPadding * 2 }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: resolvedHeight)
    }

    private func configure() {
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityIdentifier = "ChatLabComposerField"
        textView.onHeightChange = { [weak self] height in
            guard let self else { return }
            resolvedTextHeight = height
            invalidateIntrinsicContentSize()
            onHeightChange?()
        }
        textView.delegate = self
        addSubview(textView)

        placeholderLabel.text = "Message"
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: "arrow.up")
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        sendButton.configuration = config
        sendButton.accessibilityIdentifier = "ChatLabComposerSend"
        sendButton.accessibilityLabel = "Send"
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.isEnabled = false
        addSubview(sendButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            textView.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 6),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),

            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
            sendButton.widthAnchor.constraint(equalToConstant: 34),
            sendButton.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    @objc private func sendTapped() {
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend?(trimmed)
        textView.text = ""
        textView.invalidateIntrinsicContentSize()
        refreshState()
    }

    private func refreshState() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholderLabel.isHidden = !textView.text.isEmpty
        sendButton.isEnabled = hasText
    }
}

extension ComposerBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        textView.invalidateIntrinsicContentSize()
        refreshState()
    }
}
#endif
