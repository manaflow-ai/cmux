#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// Measured against iOS 26 Messages' New Message sheet (402 pt wide iPhone).
enum ComposeMetrics {
    /// The To: capsule: 16 pt from the sheet edges, 10 pt under the nav bar.
    static let fieldInset: CGFloat = 16
    static let fieldTopGap: CGFloat = 10
    static let fieldMinHeight: CGFloat = 48
    static let fieldFont = UIFont.systemFont(ofSize: 15)
    /// "To:" starts 14 pt inside the capsule; typed text 10 pt after it.
    static let toLeading: CGFloat = 14
    static let toGap: CGFloat = 10
    /// The + (Add Contact) circle: 32 pt, 9 pt from the capsule's trailing edge.
    static let addSize = CGSize(width: 32.7, height: 32)
    static let addTrailing: CGFloat = 9
    /// Token rows: 32 pt pitch, the first centered in the 48 pt capsule.
    static let lineHeight: CGFloat = 32
    static let lineTop: CGFloat = 8
    static let tokenHeight: CGFloat = 24
    static let tokenHorizontalPadding: CGFloat = 5
    static let tokenGap: CGFloat = 2
    static let textMinWidth: CGFloat = 60
}

/// A recipient token: the name in the service color (blue iMessage, green
/// SMS, red invalid, gray while looking up) followed by a comma. Selected, it
/// fills with that color and the text turns white; it is removed as a unit.
final class ComposeRecipientTokenView: UIControl {
    let label = UILabel()
    private let fill = UIView()
    private(set) var recipient: ConversationRecipient
    var isTokenSelected = false { didSet { update() } }
    /// The last token has no trailing comma when the field is empty and unfocused.
    var showsComma = true { didSet { update() } }

    init(recipient: ConversationRecipient) {
        self.recipient = recipient
        super.init(frame: .zero)
        fill.isUserInteractionEnabled = false
        fill.layer.cornerRadius = 6
        fill.layer.cornerCurve = .continuous
        addSubview(fill)
        label.font = ComposeMetrics.fieldFont
        label.isUserInteractionEnabled = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ recipient: ConversationRecipient) {
        self.recipient = recipient
        update()
    }

    static func color(for state: ConversationRecipient.State) -> UIColor {
        switch state {
        case .resolving: .secondaryLabel
        case .resolved(.iMessage): .systemBlue
        case .resolved(.sms): .systemGreen
        case .invalid: .systemRed
        }
    }

    private func update() {
        let tint = Self.color(for: recipient.state)
        fill.backgroundColor = tint
        fill.isHidden = !isTokenSelected
        let name = recipient.name
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: ComposeMetrics.fieldFont, .foregroundColor: isTokenSelected ? UIColor.white : tint,
        ])
        if showsComma && !isTokenSelected {
            text.append(NSAttributedString(string: ",", attributes: [.font: ComposeMetrics.fieldFont, .foregroundColor: UIColor.secondaryLabel]))
        }
        label.attributedText = text
        accessibilityLabel = name
        accessibilityValue = switch recipient.state {
        case .resolving: String(localized: "conversation.compose.token.searching", defaultValue: "Searching", bundle: .module)
        case .resolved(.iMessage): "iMessage"
        case .resolved(.sms): String(localized: "conversation.compose.service.sms", defaultValue: "Text Message • SMS", bundle: .module)
        case .invalid: String(localized: "conversation.compose.token.invalid", defaultValue: "Not a valid address", bundle: .module)
        }
        accessibilityIdentifier = "conversation.compose.token.\(recipient.id)"
        if isTokenSelected { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let size = label.attributedText?.size() ?? .zero
        return CGSize(width: ceil(size.width) + 2 * ComposeMetrics.tokenHorizontalPadding, height: ComposeMetrics.tokenHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = bounds
        fill.layer.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: ComposeMetrics.tokenHorizontalPadding, dy: 0)
    }
}

/// The To: text: reports Backspace on an empty field (to select or delete a token).
final class ComposeRecipientTextField: UITextField {
    var onDeleteBackward: (() -> Bool)?

    override func deleteBackward() {
        if onDeleteBackward?() == true { return }
        super.deleteBackward()
    }

    /// A selected token swallows the caret: keep the field first responder but hide it.
    var hidesCaret = false { didSet { setNeedsLayout() } }

    override func caretRect(for position: UITextPosition) -> CGRect {
        hidesCaret ? .zero : super.caretRect(for: position)
    }
}

@MainActor
protocol ComposeRecipientFieldDelegate: AnyObject {
    func recipientFieldDidChangeText(_ field: ComposeRecipientField, text: String)
    func recipientFieldDidReturn(_ field: ComposeRecipientField)
    func recipientFieldDidDeleteBackward(_ field: ComposeRecipientField) -> Bool
    func recipientField(_ field: ComposeRecipientField, didTapToken id: String)
    func recipientFieldDidTapAdd(_ field: ComposeRecipientField)
    func recipientFieldDidChangeHeight(_ field: ComposeRecipientField)
}

/// New Message's To: field: a glass capsule with "To:", wrapping recipient
/// tokens, the text being typed, and the circular + (Add Contact).
final class ComposeRecipientField: UIView, UITextFieldDelegate, UIGestureRecognizerDelegate {
    weak var delegate: (any ComposeRecipientFieldDelegate)?
    private let glass = makeGlassView(cornerRadius: ComposeMetrics.fieldMinHeight / 2)
    private let toLabel = UILabel()
    let textField = ComposeRecipientTextField()
    let addButton = UIButton(type: .system)
    private(set) var tokens: [ComposeRecipientTokenView] = []
    private(set) var preferredHeight = ComposeMetrics.fieldMinHeight
    /// Off the field, Messages collapses the recipients to one line of names
    /// and hides the +.
    private let summary = UILabel()
    private var isCollapsed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        toLabel.text = String(localized: "conversation.compose.to", defaultValue: "To:", bundle: .module)
        toLabel.font = ComposeMetrics.fieldFont
        toLabel.textColor = .secondaryLabel
        toLabel.isAccessibilityElement = false
        glass.contentView.addSubview(toLabel)

        textField.font = ComposeMetrics.fieldFont
        textField.textColor = .label
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.keyboardType = .default
        textField.returnKeyType = .default
        textField.textContentType = .name
        textField.delegate = self
        textField.accessibilityLabel = toLabel.text
        textField.accessibilityIdentifier = "conversation.compose.to"
        textField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.recipientFieldDidChangeText(self, text: self.textField.text ?? "")
        }, for: .editingChanged)
        textField.onDeleteBackward = { [weak self] in
            guard let self, (self.textField.text ?? "").isEmpty || self.selectedTokenID != nil else { return false }
            return self.delegate?.recipientFieldDidDeleteBackward(self) ?? false
        }
        glass.contentView.addSubview(textField)

        // Measured: a 13 pt bold plus on a 9% black circle (12% white in dark).
        addButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)), for: .normal)
        addButton.tintColor = .label
        addButton.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.09) }
        addButton.layer.cornerRadius = ComposeMetrics.addSize.height / 2
        addButton.accessibilityLabel = String(localized: "conversation.compose.addContact", defaultValue: "Add Contact", bundle: .module)
        addButton.accessibilityIdentifier = "conversation.compose.addContact"
        addButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.recipientFieldDidTapAdd(self)
        }, for: .touchUpInside)
        glass.contentView.addSubview(addButton)

        summary.font = ComposeMetrics.fieldFont
        summary.textColor = .label
        summary.lineBreakMode = .byTruncatingTail
        summary.isHidden = true
        glass.contentView.addSubview(summary)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedField))
        tap.delegate = self
        glass.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var selectedTokenID: String?

    func update(draft: ConversationRecipientDraft) {
        let ids = draft.recipients.map(\.id)
        if ids != tokens.map(\.recipient.id) {
            tokens.forEach { $0.removeFromSuperview() }
            tokens = draft.recipients.map { recipient in
                let token = ComposeRecipientTokenView(recipient: recipient)
                token.addAction(UIAction { [weak self, weak token] _ in
                    guard let self, let token else { return }
                    self.delegate?.recipientField(self, didTapToken: token.recipient.id)
                }, for: .touchUpInside)
                glass.contentView.insertSubview(token, belowSubview: textField)
                return token
            }
        } else {
            for (token, recipient) in zip(tokens, draft.recipients) { token.configure(recipient) }
        }
        selectedTokenID = draft.selectedID
        for token in tokens { token.isTokenSelected = token.recipient.id == draft.selectedID }
        textField.hidesCaret = draft.selectedID != nil
        if textField.text != draft.text { textField.text = draft.text }
        relayout()
    }

    @objc private func tappedField() {
        textField.becomeFirstResponder()
        if selectedTokenID != nil { delegate?.recipientField(self, didTapToken: "") }
    }

    /// Taps on tokens, the + and the text itself go to them, not the capsule.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        setCollapsed(false)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if selectedTokenID != nil { delegate?.recipientField(self, didTapToken: "") }
        setCollapsed(!tokens.isEmpty)
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        summary.text = ListFormatter.localizedString(byJoining: tokens.map(\.recipient.name))
        summary.isHidden = !collapsed
        addButton.isHidden = collapsed
        tokens.forEach { $0.isHidden = collapsed }
        relayout()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        delegate?.recipientFieldDidReturn(self)
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // A comma ends a recipient, like Return.
        if string == "," {
            delegate?.recipientFieldDidReturn(self)
            return false
        }
        return true
    }

    // MARK: Layout

    private func relayout() {
        let height = layoutContent(width: bounds.width)
        if height != preferredHeight {
            preferredHeight = height
            delegate?.recipientFieldDidChangeHeight(self)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        _ = layoutContent(width: bounds.width)
    }

    /// Flows "To:", the tokens and the text field into 32 pt lines; returns the capsule height.
    @discardableResult
    private func layoutContent(width: CGFloat) -> CGFloat {
        guard width > 0 else { return preferredHeight }
        let m = ComposeMetrics.self
        let lineCenter = { (line: Int) in m.lineTop + CGFloat(line) * m.lineHeight + m.lineHeight / 2 }
        let toSize = toLabel.intrinsicContentSize
        toLabel.frame = CGRect(x: m.toLeading, y: lineCenter(0) - toSize.height / 2, width: toSize.width, height: toSize.height)
        let start = m.toLeading + toSize.width + m.toGap - m.tokenHorizontalPadding
        if isCollapsed {
            let x = start + m.tokenHorizontalPadding
            summary.frame = CGRect(x: x, y: lineCenter(0) - 10, width: width - x - m.toLeading, height: 20)
            textField.frame = CGRect(x: width, y: 0, width: 1, height: 1)
            return m.fieldMinHeight
        }
        let right = width - m.addTrailing - m.addSize.width - 6
        var x = start
        var line = 0
        for token in tokens {
            let size = token.intrinsicContentSize
            if x + size.width > right, x > start {
                line += 1
                x = start
            }
            token.frame = CGRect(x: x, y: lineCenter(line) - m.tokenHeight / 2, width: min(size.width, right - x), height: m.tokenHeight)
            x += size.width + m.tokenGap
        }
        var textX = tokens.isEmpty ? start + m.tokenHorizontalPadding : x + 2
        if right - textX < m.textMinWidth, !tokens.isEmpty {
            line += 1
            textX = start + m.tokenHorizontalPadding
        }
        textField.frame = CGRect(x: textX, y: lineCenter(line) - 15, width: max(m.textMinWidth, right - textX), height: 30)
        let height = max(m.fieldMinHeight, m.lineTop * 2 + CGFloat(line + 1) * m.lineHeight)
        // The + stays on the last line, as in Messages.
        addButton.frame = CGRect(x: width - m.addTrailing - m.addSize.width, y: height - m.lineTop - m.addSize.height, width: m.addSize.width, height: m.addSize.height)
        return height
    }
}
#endif
