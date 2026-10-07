#if os(macOS)
import AppKit
import CmuxConversationCore

/// A group status row ("Lawrence Chen named the conversation “cmux”."): the
/// timestamp separator's font and gray, the actor's name semibold (ChatKit's
/// `#…#` span), centered and wrapping within the transcript's side margins.
final class MacSystemEventRowView: MacFlippedView {
    let label = makeMacLabel()
    static let sideInset: CGFloat = 24
    static let top: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: ConversationSystemText) {
        label.attributedStringValue = Self.attributed(text)
        setAccessibilityLabel(text.text)
        needsLayout = true
    }

    static func attributed(_ text: ConversationSystemText) -> NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString(string: text.text, attributes: [
            .font: MacConversationTheme.timestampFont, .foregroundColor: MacConversationTheme.secondaryText, .paragraphStyle: centered,
        ])
        for range in text.emphasized where NSMaxRange(range) <= result.length {
            result.addAttribute(.font, value: MacConversationTheme.timestampBoldFont, range: range)
        }
        return result
    }

    static func textHeight(_ text: ConversationSystemText, width: CGFloat) -> CGFloat {
        let bounds = attributed(text).boundingRect(
            with: NSSize(width: max(1, width - 2 * sideInset), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(14, ceil(bounds.height))
    }

    /// One line matches the timestamp separator; each extra line adds its height.
    static func height(_ text: ConversationSystemText, width: CGFloat) -> CGFloat {
        MacTimestampRowView.height + textHeight(text, width: width) - 14
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 2 * Self.sideInset
        let height = label.attributedStringValue.boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        label.frame = CGRect(x: Self.sideInset, y: Self.top, width: width, height: max(14, ceil(height)))
    }
}

/// "John has notifications silenced" with a moon, under the newest message
/// of a 1:1 conversation whose recipient has a Focus on, and a blue Notify
/// Anyway while my newest message was delivered quietly.
final class MacUnavailabilityRowView: MacFlippedView {
    let label = makeMacLabel()
    let button = NSButton(title: "", target: nil, action: nil)
    var onNotifyAnyway: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        label.setAccessibilityIdentifier("conversation.unavailability")
        button.isBordered = false
        button.target = self
        button.action = #selector(notifyAnyway)
        button.setAccessibilityIdentifier("conversation.notifyAnyway")
        addSubview(label)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, showsNotifyAnyway: Bool) {
        let font = MacConversationTheme.timestampFont
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let text = NSMutableAttributedString()
        if let moon = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .medium).applying(.init(hierarchicalColor: MacConversationTheme.secondaryText))) {
            let attachment = NSTextAttachment()
            attachment.image = moon
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: ConversationStatusStrings.notificationsSilenced(name)))
        text.addAttributes([.font: font, .foregroundColor: MacConversationTheme.secondaryText, .paragraphStyle: centered], range: NSRange(location: 0, length: text.length))
        label.attributedStringValue = text
        label.setAccessibilityLabel(ConversationStatusStrings.notificationsSilenced(name))
        button.attributedTitle = NSAttributedString(string: ConversationStatusStrings.notifyAnyway, attributes: [
            .font: MacConversationTheme.timestampBoldFont, .foregroundColor: NSColor.linkColor, .paragraphStyle: centered,
        ])
        button.isHidden = !showsNotifyAnyway
        needsLayout = true
    }

    static func height(showsNotifyAnyway: Bool) -> CGFloat {
        MacTimestampRowView.height + (showsNotifyAnyway ? 18 : 0)
    }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 0, y: 8, width: bounds.width, height: 14)
        let size = button.intrinsicContentSize
        button.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: label.frame.maxY + 2, width: size.width, height: 16)
    }

    @objc private func notifyAnyway() {
        onNotifyAnyway?()
    }
}
#endif
