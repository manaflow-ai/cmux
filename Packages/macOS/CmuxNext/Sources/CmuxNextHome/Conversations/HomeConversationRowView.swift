import AppKit
import CmuxHomeCore
import CmuxNextDesign

/// One conversation in the Home page's list: a monogram, the title, the
/// newest message, its time, and the unread and mention badges.
final class HomeConversationCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("home.conversation")
    static var height: CGFloat { Metrics.sidebarRowHeightWithSubtitle + Metrics.space2 }

    let avatar = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    let preview = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    let mention = NSTextField(labelWithString: "@")
    private let disc = CALayer()
    private(set) var row: InboxRow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        layer?.addSublayer(disc)
        for label in [avatar, title, preview, time, badge, mention] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        avatar.alignment = .center
        badge.alignment = .center
        badge.wantsLayer = true
        mention.alignment = .center
        mention.wantsLayer = true
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ row: InboxRow, me: ParticipantID?) {
        self.row = row
        let other = row.summary.participants.first { $0.id != me }
        avatar.stringValue = row.kind == .group ? String(row.summary.participants.count - 1) : (other?.initials ?? "?")
        title.stringValue = row.title.isEmpty ? HomeConversationStrings.untitled : row.title
        let invited = row.kind == .direct && row.summary.hasInvitedParticipant
        preview.stringValue = invited && row.preview.isEmpty ? HomeConversationStrings.invitedLabel : Self.previewText(row)
        time.stringValue = Self.timeText(row.timestamp)
        badge.stringValue = row.unread > 99 ? "99+" : String(row.unread)
        badge.isHidden = row.unread == 0
        mention.isHidden = row.mentions == 0
        title.font = row.unread > 0 ? Typography.bodyEmphasized : Typography.body
        setAccessibilityLabel(Self.accessibilityText(row, preview: preview.stringValue, title: title.stringValue))
        applyColors()
        needsLayout = true
    }

    static func previewText(_ row: InboxRow) -> String {
        let text = row.preview.replacingOccurrences(of: "\n", with: " ")
        guard row.kind == .group, let author = row.previewAuthor, !author.isEmpty, !text.isEmpty else { return text }
        return "\(author): \(text)"
    }

    static func timeText(_ date: Date, now: Date = Date()) -> String {
        guard date > .distantPast else { return "" }
        if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// What VoiceOver reads for the row: the title, unread and mention
    /// state, pinned, then the newest message.
    static func accessibilityText(_ row: InboxRow, preview: String, title: String) -> String {
        var parts = [title]
        if row.unread > 0 { parts.append(HomeConversationStrings.unread(row.unread)) }
        if row.mentions > 0 { parts.append(HomeConversationStrings.mentioned) }
        if row.isPinned { parts.append(HomeConversationStrings.pinnedLabel) }
        if !preview.isEmpty { parts.append(preview) }
        return parts.joined(separator: ", ")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            disc.backgroundColor = (row?.kind == .chief ? Palette.highlight.withAlphaComponent(0.25) : Palette.elevatedBackground).cgColor
            avatar.textColor = Palette.textPrimary
            avatar.font = Typography.caption
            title.textColor = Palette.textPrimary
            preview.textColor = Palette.textSecondary
            preview.font = Typography.caption
            time.textColor = Palette.textTertiary
            time.font = Typography.caption
            badge.font = Typography.shortcut
            badge.textColor = Palette.highlightText
            badge.layer?.backgroundColor = Palette.highlight.cgColor
            mention.font = Typography.shortcut
            mention.textColor = Palette.highlightText
            mention.layer?.backgroundColor = Palette.highlight.cgColor
        }
    }

    override func layout() {
        super.layout()
        let inset = Metrics.space3
        let size = Metrics.sidebarRowHeight + Metrics.space1
        let disc = CGRect(x: inset, y: (bounds.height - size) / 2, width: size, height: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.disc.frame = disc
        self.disc.cornerRadius = size / 2
        CATransaction.commit()
        let avatarHeight = avatar.intrinsicContentSize.height
        avatar.frame = CGRect(x: disc.minX, y: disc.midY - avatarHeight / 2, width: size, height: avatarHeight)
        let textX = disc.maxX + Metrics.space2
        let timeWidth = ceil(time.intrinsicContentSize.width)
        let lineHeight = ceil(title.intrinsicContentSize.height)
        let previewHeight = ceil(preview.intrinsicContentSize.height)
        let top = (bounds.height - lineHeight - previewHeight) / 2
        time.frame = CGRect(x: bounds.width - inset - timeWidth, y: top + previewHeight, width: timeWidth, height: lineHeight)
        title.frame = CGRect(x: textX, y: top + previewHeight, width: max(0, time.frame.minX - Metrics.space2 - textX), height: lineHeight)
        let pill = previewHeight
        var trailing = bounds.width - inset
        for view in [badge, mention] where !view.isHidden {
            let width = max(pill, ceil(view.intrinsicContentSize.width) + Metrics.space2)
            view.frame = CGRect(x: trailing - width, y: top, width: width, height: pill)
            view.layer?.cornerRadius = pill / 2
            trailing = view.frame.minX - Metrics.space1
        }
        preview.frame = CGRect(x: textX, y: top, width: max(0, trailing - Metrics.space1 - textX), height: previewHeight)
    }
}

/// A section title in the list ("Chiefs", "Pinned", ...).
final class HomeConversationHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("home.conversation.header")
    static var height: CGFloat { Metrics.sidebarHeaderHeight }
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ kind: HomeConversationSectionKind) {
        label.stringValue = HomeConversationStrings.header(kind)
        setAccessibilityLabel(label.stringValue)
        performWithTheme {
            label.font = Typography.header
            label.textColor = Palette.textSecondary
        }
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: Metrics.space3, y: Metrics.space1, width: bounds.width - 2 * Metrics.space3, height: height)
    }
}

/// The row's selection and hover fills in the theme's colours.
final class HomeConversationTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        performWithTheme {
            (isEmphasized ? Palette.selectionFill : Palette.secondarySelectionFill).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: Metrics.space2, dy: 1), xRadius: Metrics.itemCornerRadius,
                         yRadius: Metrics.itemCornerRadius).fill()
        }
    }
}
