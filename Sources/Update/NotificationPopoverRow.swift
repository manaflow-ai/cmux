import AppKit
import CmuxFoundation

@MainActor
final class NotificationPopoverRowNativeView: NSView {
    private let primaryButton = NSButton()
    private let unreadStripe = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let notificationTitleField = NSTextField(labelWithString: "")
    private let bodyField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private let textStack = NSStackView()
    private var tracking: NSTrackingArea?
    private var notification: TerminalNotification?
    private var onOpen: () -> Void = {}
    private var onClear: () -> Void = {}
    private var onToggleRead: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let hasWorkspaceTitle = !notificationTitleField.isHidden
        let hasBody = !bodyField.isHidden
        let lineHeight: CGFloat = 15
        let estimated = 16 + lineHeight
            + (hasWorkspaceTitle ? 15 : 0)
            + (hasBody ? 28 : 0)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(56, estimated))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        primaryButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.11).cgColor
        clearButton.isHidden = false
        clearButton.setAccessibilityElement(true)
    }

    override func mouseExited(with event: NSEvent) {
        primaryButton.layer?.backgroundColor = NSColor.clear.cgColor
        clearButton.isHidden = true
        clearButton.setAccessibilityElement(false)
    }

    func update(
        notification: TerminalNotification,
        workspaceTitle: String?,
        onOpen: @escaping () -> Void,
        onClear: @escaping () -> Void,
        onToggleRead: @escaping () -> Void
    ) {
        self.notification = notification
        self.onOpen = onOpen
        self.onClear = onClear
        self.onToggleRead = onToggleRead

        let workspaceTitle = workspaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWorkspaceTitle = workspaceTitle?.isEmpty == false
        titleField.stringValue = hasWorkspaceTitle ? workspaceTitle! : notification.title
        notificationTitleField.stringValue = notification.title
        notificationTitleField.isHidden = !hasWorkspaceTitle
        bodyField.stringValue = notification.body
        bodyField.isHidden = notification.body.isEmpty
        timeField.stringValue = notification.createdAt.formatted(date: .omitted, time: .shortened)
        unreadStripe.layer?.backgroundColor = notification.isRead
            ? NSColor.clear.cgColor
            : cmuxAccentNSColor().cgColor

        let identifier = "NotificationPopoverRow.\(notification.id.uuidString)"
        primaryButton.setAccessibilityIdentifier(identifier)
        primaryButton.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(
                name: String(localized: "notifications.row.clear", defaultValue: "Clear notification"),
                handler: { [weak self] in
                    self?.onClear()
                    return true
                }
            ),
        ])
        titleField.setAccessibilityIdentifier("\(identifier).workspaceTitle")
        rebuildContextMenu(notification: notification)
        invalidateIntrinsicContentSize()
    }

    private func configureViews() {
        primaryButton.isBordered = false
        primaryButton.title = ""
        primaryButton.wantsLayer = true
        primaryButton.target = self
        primaryButton.action = #selector(openNotification(_:))
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.setAccessibilityRole(.button)
        addSubview(primaryButton)

        unreadStripe.wantsLayer = true
        unreadStripe.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.addSubview(unreadStripe)

        titleField.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        notificationTitleField.font = .systemFont(ofSize: 10.5, weight: .medium)
        notificationTitleField.textColor = .secondaryLabelColor
        notificationTitleField.lineBreakMode = .byTruncatingTail
        notificationTitleField.maximumNumberOfLines = 1

        bodyField.font = .systemFont(ofSize: 11.5)
        bodyField.textColor = .secondaryLabelColor
        bodyField.lineBreakMode = .byTruncatingTail
        bodyField.maximumNumberOfLines = 2

        timeField.font = .systemFont(ofSize: 10.5)
        timeField.textColor = .secondaryLabelColor
        timeField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let topRow = NSStackView(views: [titleField, timeField])
        topRow.orientation = .horizontal
        topRow.alignment = .firstBaseline
        topRow.spacing = 6

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(topRow)
        textStack.addArrangedSubview(notificationTitleField)
        textStack.addArrangedSubview(bodyField)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.addSubview(textStack)

        clearButton.bezelStyle = .circular
        clearButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(localized: "notifications.row.clear", defaultValue: "Clear notification")
        )
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearNotification(_:))
        clearButton.isHidden = true
        clearButton.setAccessibilityElement(false)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            primaryButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            primaryButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            primaryButton.topAnchor.constraint(equalTo: topAnchor),
            primaryButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            unreadStripe.leadingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: 4),
            unreadStripe.topAnchor.constraint(equalTo: primaryButton.topAnchor, constant: 6),
            unreadStripe.bottomAnchor.constraint(equalTo: primaryButton.bottomAnchor, constant: -6),
            unreadStripe.widthAnchor.constraint(equalToConstant: 2.5),
            textStack.leadingAnchor.constraint(equalTo: unreadStripe.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: primaryButton.trailingAnchor, constant: -44),
            textStack.topAnchor.constraint(equalTo: primaryButton.topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: primaryButton.bottomAnchor, constant: -8),
            topRow.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            notificationTitleField.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            bodyField.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 20),
            clearButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private func rebuildContextMenu(notification: TerminalNotification) {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "notifications.open", defaultValue: "Open"), action: #selector(openNotification(_:)), keyEquivalent: "")
        let toggleTitle = notification.isRead
            ? String(localized: "notifications.markAsUnread", defaultValue: "Mark as Unread")
            : String(localized: "notifications.markAsRead", defaultValue: "Mark as Read")
        menu.addItem(withTitle: toggleTitle, action: #selector(toggleRead(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "notifications.dismiss", defaultValue: "Dismiss"), action: #selector(clearNotification(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        self.menu = menu
        primaryButton.menu = menu
    }

    @objc private func openNotification(_ sender: Any?) { onOpen() }
    @objc private func clearNotification(_ sender: Any?) { onClear() }
    @objc private func toggleRead(_ sender: Any?) { onToggleRead() }
}
