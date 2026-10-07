#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// A group status row ("Lawrence Chen named the conversation “cmux”."):
/// centered in the separator's caption 2 gray, the actor's name semibold
/// (ChatKit's `#…#` span), wrapping inside the separator's margins.
final class SystemEventCell: UICollectionViewCell {
    static let reuseID = "systemEvent"
    /// The timestamp separator's side margins and top offset.
    static let sideInset: CGFloat = 16
    static let top: CGFloat = 10
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.textAlignment = .center
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: ConversationSystemText) {
        label.attributedText = Self.attributed(text)
        accessibilityLabel = text.text
        setNeedsLayout()
    }

    static func attributed(_ text: ConversationSystemText) -> NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let result = NSMutableAttributedString(string: text.text, attributes: [
            .font: ConversationTheme.timestampFont,
            .foregroundColor: ConversationTheme.timestampText,
            .paragraphStyle: centered,
        ])
        for range in text.emphasized where NSMaxRange(range) <= result.length {
            result.addAttribute(.font, value: ConversationTheme.timestampBoldFont, range: range)
        }
        return result
    }

    static func textHeight(_ text: ConversationSystemText, width: CGFloat) -> CGFloat {
        let bounds = attributed(text).boundingRect(
            with: CGSize(width: max(1, width - 2 * sideInset), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
        return ceil(bounds.height)
    }

    /// One line matches the timestamp separator; each extra line adds its height.
    static func height(_ text: ConversationSystemText, width: CGFloat) -> CGFloat {
        let line = ceil(ConversationTheme.timestampFont.lineHeight)
        return TimestampCell.height + max(0, textHeight(text, width: width) - line)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width - 2 * Self.sideInset
        let height = label.attributedText.map {
            ceil($0.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        } ?? 0
        label.frame = CGRect(x: Self.sideInset, y: Self.top, width: width, height: max(height, ceil(ConversationTheme.timestampFont.lineHeight)))
    }
}

/// "John has notifications silenced" with a moon, under the newest message
/// of a 1:1 conversation whose recipient has a Focus on, and Notify Anyway
/// (blue) while my newest message was delivered quietly.
final class UnavailabilityCell: UICollectionViewCell {
    static let reuseID = "unavailability"
    private let label = UILabel()
    private let button = UIButton(type: .system)
    var onNotifyAnyway: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.accessibilityIdentifier = "conversation.unavailability"
        button.titleLabel?.font = ConversationTheme.timestampBoldFont
        button.accessibilityIdentifier = "conversation.notifyAnyway"
        button.addTarget(self, action: #selector(notifyAnyway), for: .touchUpInside)
        contentView.addSubview(label)
        contentView.addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, showsNotifyAnyway: Bool) {
        label.attributedText = Self.text(name: name)
        label.accessibilityLabel = ConversationStatusStrings.notificationsSilenced(name)
        button.setTitle(ConversationStatusStrings.notifyAnyway, for: .normal)
        button.titleLabel?.font = ConversationTheme.timestampBoldFont
        button.isHidden = !showsNotifyAnyway
        setNeedsLayout()
    }

    static func text(name: String) -> NSAttributedString {
        let font = ConversationTheme.timestampFont
        let moon = UIImage(systemName: "moon.fill", withConfiguration: UIImage.SymbolConfiguration(font: font))?
            .withTintColor(ConversationTheme.timestampText, renderingMode: .alwaysOriginal)
        let result = NSMutableAttributedString()
        if let moon { result.append(NSAttributedString(attachment: NSTextAttachment(image: moon))) }
        result.append(NSAttributedString(string: " " + ConversationStatusStrings.notificationsSilenced(name), attributes: [
            .font: font, .foregroundColor: ConversationTheme.timestampText,
        ]))
        return result
    }

    private static var line: CGFloat { ceil(ConversationTheme.timestampFont.lineHeight) }
    private static let gap: CGFloat = 2

    static func height(showsNotifyAnyway: Bool) -> CGFloat {
        TimestampCell.height + (showsNotifyAnyway ? line + 2 * gap + 6 : 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width - 2 * SystemEventCell.sideInset
        label.frame = CGRect(x: SystemEventCell.sideInset, y: SystemEventCell.top, width: width, height: Self.line)
        // A comfortable tap target around the one-line title.
        let size = button.intrinsicContentSize
        button.frame = CGRect(x: (contentView.bounds.width - size.width) / 2, y: label.frame.maxY + Self.gap, width: size.width, height: max(Self.line + 2 * Self.gap, min(size.height, 30)))
    }

    @objc private func notifyAnyway() {
        onNotifyAnyway?()
    }
}
#endif
