#if canImport(UIKit)
import UIKit

/// The composer bar. It IS the keyboard's `inputAccessoryView` (vended by the
/// view controller), so the responder infrastructure moves it with the keyboard
/// frame for frame, including through an interactive swipe-to-dismiss.
///
/// Layout: a single Liquid Glass capsule "pill" (`UIGlassEffect` on iOS 26,
/// thick-material fallback below) holds the growing text view AND the send
/// button (bottom-trailing, inside the pill, iMessage-style). The pill's bottom
/// pins to the safe-area guide, so when the keyboard is down the bar sits just
/// above the home indicator rather than under it; the bar's intrinsic height
/// includes that safe-area inset only while docked.
final class ComposerBar: UIInputView {
    private let pill = ComposerBar.makeGlassPill()
    private let textView = GrowingTextView()
    private let sendButton = UIButton(type: .system)
    private let placeholderLabel = UILabel()

    /// Invoked with the trimmed prompt when the user taps send.
    var onSend: ((String) -> Void)?
    /// Invoked whenever the bar's height changes (text grew/shrank) so the
    /// owner can refresh the accessory's intrinsic size and re-sync the list.
    var onHeightChange: (() -> Void)?

    private let verticalPadding: CGFloat = 8
    private let minTextHeight: CGFloat = 38
    private let maxTextHeight: CGFloat = 140
    private var resolvedTextHeight: CGFloat = 38
    private var textHeightConstraint: NSLayoutConstraint!

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 54), inputViewStyle: .keyboard)
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

    /// The visible bar height WITHOUT the bottom safe-area inset. The owner adds
    /// its own safe-area inset when computing the list overlap, so this stays
    /// safe-area-free to avoid double counting.
    var barContentHeight: CGFloat { resolvedTextHeight + verticalPadding * 2 }

    override var intrinsicContentSize: CGSize {
        // Include the home-indicator inset only while docked (safeAreaInsets is
        // zero while riding the raised keyboard).
        CGSize(width: UIView.noIntrinsicMetric, height: barContentHeight + safeAreaInsets.bottom)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.layer.cornerRadius = min(pill.bounds.height / 2, 22)
        recomputeHeight()
    }

    private func configure() {
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.clipsToBounds = true
        pill.layer.cornerCurve = .continuous
        addSubview(pill)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityIdentifier = "ChatLabComposerField"
        textView.delegate = self
        pill.contentView.addSubview(textView)

        placeholderLabel.text = "Message"
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.isAccessibilityElement = false
        pill.contentView.addSubview(placeholderLabel)

        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: "arrow.up")
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
        sendButton.configuration = config
        sendButton.accessibilityIdentifier = "ChatLabComposerSend"
        sendButton.accessibilityLabel = "Send"
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.isEnabled = false
        pill.contentView.addSubview(sendButton)

        textHeightConstraint = textView.heightAnchor.constraint(equalToConstant: minTextHeight)

        NSLayoutConstraint.activate([
            // Pill spans the full width; bottom pins to the safe area so the bar
            // rides above the home indicator when the keyboard is down.
            pill.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            pill.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -verticalPadding),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            textView.topAnchor.constraint(equalTo: pill.contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 10),
            // Text never runs under the send button.
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
            textHeightConstraint,

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 11),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),

            // Send button lives INSIDE the pill, bottom-trailing.
            sendButton.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -5),
            sendButton.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -4),
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    /// Resolves the clamped text height and pushes it to the constraint. Only
    /// acts on an actual change so `layoutSubviews` can call it cheaply.
    private func recomputeHeight() {
        let width = textView.bounds.width
        guard width > 0 else { return }
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let result = GrowingTextHeightSolver.solve(
            fittingHeight: fitting,
            minHeight: minTextHeight,
            maxHeight: maxTextHeight
        )
        if textView.isScrollEnabled != result.scrollEnabled {
            textView.isScrollEnabled = result.scrollEnabled
        }
        guard abs(result.height - resolvedTextHeight) > 0.5 else { return }
        resolvedTextHeight = result.height
        textHeightConstraint.constant = result.height
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    @objc private func sendTapped() {
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend?(trimmed)
        textView.text = ""
        refreshState()
        recomputeHeight()
    }

    private func refreshState() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholderLabel.isHidden = !textView.text.isEmpty
        sendButton.isEnabled = hasText
    }

    /// A Liquid Glass capsule on iOS 26+, a thick-material capsule below that.
    private static func makeGlassPill() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect())
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    }
}

extension ComposerBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshState()
        recomputeHeight()
    }
}
#endif
