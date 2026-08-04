import AppKit
import Combine
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

@MainActor
private final class NotificationsPopoverRowsView: NSView {
    var rows: [NotificationPopoverRowNativeView] = [] {
        didSet {
            for view in subviews where !rows.contains(where: { $0 === view }) {
                view.removeFromSuperview()
            }
            for row in rows where row.superview !== self {
                addSubview(row)
            }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: rows.reduce(0) { $0 + $1.intrinsicContentSize.height }
        )
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for row in rows {
            let height = row.intrinsicContentSize.height
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
        if frame.height != y {
            frame.size.height = y
        }
    }
}

@MainActor
final class NotificationsPopoverViewController: NSViewController {
    private static let widthDefaultsKey = "cmux.notifications.popover.width"
    private static let heightDefaultsKey = "cmux.notifications.popover.height"
    private static let screenMargin: CGFloat = 80

    private let notificationStore: TerminalNotificationStore
    private let onDismiss: () -> Void
    private let defaults: UserDefaults
    private let headerView = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let unreadBadge = NSTextField(labelWithString: "")
    private let jumpButton = NSButton()
    private let clearButton = NSButton()
    private let divider = NSBox()
    private let scrollView = NSScrollView()
    private let rowsView = NotificationsPopoverRowsView()
    private let emptyStateView = NSView()
    private let emptyImageView = NSImageView()
    private let emptyTitleField = NSTextField(labelWithString: "")
    private let emptySubtitleField = NSTextField(wrappingLabelWithString: "")
    private let resizeGripper = ResizeGripperNSView()
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var loadedWorkspaceTitles: [UUID: String] = [:]
    private var liveSize: NSSize?

    init(
        notificationStore: TerminalNotificationStore,
        defaults: UserDefaults = .standard,
        onDismiss: @escaping () -> Void
    ) {
        self.notificationStore = notificationStore
        self.defaults = defaults
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: clampedStoredSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
        preferredContentSize = root.frame.size
        configureViews()
        observeModels()
        refreshWorkspaceTitles()
        refreshContent()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let headerHeight: CGFloat = 48
        headerView.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        divider.frame = NSRect(x: 0, y: headerView.frame.minY - 1, width: bounds.width, height: 1)
        let contentFrame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, divider.frame.minY))
        scrollView.frame = contentFrame
        emptyStateView.frame = contentFrame
        resizeGripper.frame = NSRect(x: bounds.maxX - 16, y: 0, width: 16, height: 16)
        layoutHeader()
        layoutEmptyState()
        rowsView.frame.size.width = scrollView.contentSize.width
        rowsView.needsLayout = true
        rowsView.layoutSubtreeIfNeeded()
    }

    private var clampedStoredSize: NSSize {
        let savedWidth = defaults.object(forKey: Self.widthDefaultsKey) as? Double
            ?? Double(NotificationsPopoverMetrics.defaultWidth)
        let savedHeight = defaults.object(forKey: Self.heightDefaultsKey) as? Double
            ?? Double(NotificationsPopoverMetrics.defaultHeight)
        return clamp(size: NSSize(width: savedWidth, height: savedHeight))
    }

    private func clamp(size: NSSize) -> NSSize {
        let screen = viewIfLoaded?.window?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        let screenWidth = screen?.visibleFrame.width ?? NotificationsPopoverMetrics.maxWidth
        let screenHeight = screen?.visibleFrame.height ?? NotificationsPopoverMetrics.maxHeight
        let maxWidth = min(
            NotificationsPopoverMetrics.maxWidth,
            max(NotificationsPopoverMetrics.minWidth, screenWidth - Self.screenMargin)
        )
        let maxHeight = min(
            NotificationsPopoverMetrics.maxHeight,
            max(NotificationsPopoverMetrics.minHeight, screenHeight - Self.screenMargin)
        )
        return NSSize(
            width: min(maxWidth, max(NotificationsPopoverMetrics.minWidth, size.width)),
            height: min(maxHeight, max(NotificationsPopoverMetrics.minHeight, size.height))
        )
    }

    private func configureViews() {
        view.addSubview(headerView)
        view.addSubview(divider)
        view.addSubview(scrollView)
        view.addSubview(emptyStateView)
        view.addSubview(resizeGripper)

        titleField.stringValue = String(localized: "notifications.title", defaultValue: "Notifications")
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        headerView.addSubview(titleField)

        unreadBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        unreadBadge.textColor = .white
        unreadBadge.alignment = .center
        unreadBadge.wantsLayer = true
        headerView.addSubview(unreadBadge)

        jumpButton.bezelStyle = .rounded
        jumpButton.controlSize = .small
        jumpButton.image = NSImage(
            systemSymbolName: "arrow.down.to.line",
            accessibilityDescription: String(
                localized: "notifications.jumpToLatest",
                defaultValue: "Jump to Latest"
            )
        )
        jumpButton.imagePosition = .imageLeading
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLatestUnread(_:))
        jumpButton.setAccessibilityIdentifier("notificationsPopover.jumpToLatest")
        headerView.addSubview(jumpButton)

        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.title = String(localized: "notifications.clearAll", defaultValue: "Clear All")
        clearButton.target = self
        clearButton.action = #selector(clearAll(_:))
        clearButton.setAccessibilityIdentifier("notificationsPopover.clearAll")
        headerView.addSubview(clearButton)

        divider.boxType = .separator

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = rowsView

        emptyImageView.imageScaling = .scaleProportionallyDown
        emptyImageView.contentTintColor = .secondaryLabelColor
        emptyStateView.addSubview(emptyImageView)
        emptyTitleField.alignment = .center
        emptyTitleField.font = .systemFont(ofSize: 14, weight: .medium)
        emptyStateView.addSubview(emptyTitleField)
        emptySubtitleField.alignment = .center
        emptySubtitleField.font = .systemFont(ofSize: 12)
        emptySubtitleField.textColor = .secondaryLabelColor
        emptySubtitleField.maximumNumberOfLines = 2
        emptyStateView.addSubview(emptySubtitleField)

        resizeGripper.setAccessibilityLabel(
            String(localized: "notifications.resize", defaultValue: "Resize notifications")
        )
        resizeGripper.setAccessibilityHelp(
            String(
                localized: "notifications.resize.hint",
                defaultValue: "Drag to resize the notifications popover"
            )
        )
        resizeGripper.onBegin = { [weak self] in
            guard let self else { return (0, 0) }
            return (view.bounds.width, view.bounds.height)
        }
        resizeGripper.onDrag = { [weak self] startWidth, startHeight, dx, dy in
            guard let self else { return }
            let next = clamp(size: NSSize(width: startWidth + dx, height: startHeight + dy))
            liveSize = next
            apply(size: next)
        }
        resizeGripper.onEnd = { [weak self] in
            guard let self, let liveSize else { return }
            defaults.set(Double(liveSize.width), forKey: Self.widthDefaultsKey)
            defaults.set(Double(liveSize.height), forKey: Self.heightDefaultsKey)
            self.liveSize = nil
        }
    }

    private func observeModels() {
        notificationStore.$notifications
            .combineLatest(notificationStore.$notificationMenuSnapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.refreshWorkspaceTitles()
                self.refreshContent()
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .workspaceTitleDidChange,
            .workspaceGroupNameDidChange,
            .workspaceOrderDidChange,
            KeyboardShortcutSettings.didChangeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if notification.name == KeyboardShortcutSettings.didChangeNotification {
                        self.refreshHeader()
                    } else {
                        self.refreshWorkspaceTitles(ifRelevantTo: notification)
                        self.refreshRows()
                    }
                }
            })
        }
    }

    private func layoutHeader() {
        let padding: CGFloat = 14
        titleField.sizeToFit()
        titleField.frame.origin = NSPoint(
            x: padding,
            y: (headerView.bounds.height - titleField.frame.height) / 2
        )

        unreadBadge.sizeToFit()
        let badgeWidth = max(22, unreadBadge.frame.width + 12)
        unreadBadge.frame = NSRect(
            x: titleField.frame.maxX + 8,
            y: (headerView.bounds.height - 18) / 2,
            width: badgeWidth,
            height: 18
        )
        unreadBadge.layer?.cornerRadius = 9
        unreadBadge.layer?.backgroundColor = cmuxAccentNSColor().cgColor

        clearButton.sizeToFit()
        clearButton.frame.origin = NSPoint(
            x: headerView.bounds.maxX - padding - clearButton.frame.width,
            y: (headerView.bounds.height - clearButton.frame.height) / 2
        )
        jumpButton.sizeToFit()
        jumpButton.frame.origin = NSPoint(
            x: clearButton.frame.minX - 8 - jumpButton.frame.width,
            y: (headerView.bounds.height - jumpButton.frame.height) / 2
        )
    }

    private func layoutEmptyState() {
        let centerX = emptyStateView.bounds.midX
        let centerY = emptyStateView.bounds.midY
        emptyImageView.frame = NSRect(x: centerX - 16, y: centerY + 20, width: 32, height: 32)
        emptyTitleField.frame = NSRect(x: 24, y: centerY - 4, width: max(0, emptyStateView.bounds.width - 48), height: 20)
        emptySubtitleField.frame = NSRect(x: 24, y: centerY - 42, width: max(0, emptyStateView.bounds.width - 48), height: 34)
    }

    private func apply(size: NSSize) {
        preferredContentSize = size
        view.frame.size = size
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func refreshContent() {
        refreshHeader()
        refreshRows()
    }

    private func refreshHeader() {
        let snapshot = notificationStore.notificationMenuSnapshot
        unreadBadge.stringValue = String(snapshot.unreadCount)
        unreadBadge.isHidden = snapshot.unreadCount == 0

        let shortcut = KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
        let baseTitle = String(localized: "notifications.jumpToLatest", defaultValue: "Jump to Latest")
        jumpButton.title = shortcut.displayString.isEmpty
            ? baseTitle
            : "\(baseTitle)  \(shortcut.displayString)"
        jumpButton.isEnabled = snapshot.hasUnreadNotifications
        jumpButton.setAccessibilityValue(shortcut.displayString)
        jumpButton.toolTip = KeyboardShortcutSettings.Action.jumpToUnread.tooltip(baseTitle)
        clearButton.isEnabled = snapshot.hasNotifications
        layoutHeader()
    }

    private func refreshRows() {
        let notifications = notificationStore.notifications
        if notifications.isEmpty {
            rowsView.rows = []
            scrollView.isHidden = true
            emptyStateView.isHidden = false
            let snapshot = notificationStore.notificationMenuSnapshot
            let imageName = snapshot.hasNotifications ? "bell.badge" : "bell.slash"
            emptyImageView.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
            emptyTitleField.stringValue = snapshot.hasNotifications
                ? snapshot.stateHintTitle
                : String(localized: "notifications.empty.title", defaultValue: "No notifications yet")
            emptySubtitleField.stringValue = snapshot.hasNotifications
                ? ""
                : String(
                    localized: "notifications.empty.subtitle",
                    defaultValue: "Desktop notifications will appear here."
                )
            emptySubtitleField.isHidden = emptySubtitleField.stringValue.isEmpty
            view.needsLayout = true
            return
        }

        emptyStateView.isHidden = true
        scrollView.isHidden = false
        rowsView.rows = notifications.map { notification in
            let row = NotificationPopoverRowNativeView()
            row.update(
                notification: notification,
                workspaceTitle: loadedWorkspaceTitles[notification.tabId],
                onOpen: { [weak self] in self?.open(notification) },
                onClear: { [weak self] in self?.notificationStore.remove(id: notification.id) },
                onToggleRead: { [weak self] in self?.toggleRead(notification) }
            )
            return row
        }
        rowsView.frame = NSRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: rowsView.intrinsicContentSize.height
        )
        rowsView.needsLayout = true
    }

    private func currentWorkspaceTitles() -> [UUID: String] {
        let ids = Set(notificationStore.notifications.map(\.tabId))
        return AppDelegate.shared?.tabTitlesByTabId(for: ids) ?? [:]
    }

    private func refreshWorkspaceTitles(ifRelevantTo notification: Notification? = nil) {
        let notificationWorkspaceIDs = Set(notificationStore.notifications.map(\.tabId))
        guard let notification else {
            loadedWorkspaceTitles = currentWorkspaceTitles()
            return
        }
        guard let manager = notification.object as? TabManager else { return }

        let changedWorkspaceIDs: Set<UUID>
        let changedTitles: [UUID: String]
        switch notification.name {
        case .workspaceTitleDidChange:
            guard let workspaceID = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            changedWorkspaceIDs = [workspaceID]
            changedTitles = manager.resolvedWorkspaceDisplayTitle(forWorkspaceId: workspaceID)
                .map { [workspaceID: $0] } ?? [:]
        case .workspaceGroupNameDidChange:
            changedTitles = manager.resolvedWorkspaceDisplayTitles(for: notificationWorkspaceIDs)
            changedWorkspaceIDs = Set(changedTitles.keys)
        case .workspaceOrderDidChange:
            changedWorkspaceIDs = Set(
                notification.userInfo?[WorkspaceOrderChangeNotificationKey.movedWorkspaceIds] as? [UUID] ?? []
            )
            changedTitles = manager.resolvedWorkspaceDisplayTitles(for: changedWorkspaceIDs)
        default:
            return
        }

        for workspaceID in changedWorkspaceIDs.intersection(notificationWorkspaceIDs) {
            if let title = changedTitles[workspaceID] {
                loadedWorkspaceTitles[workspaceID] = title
            } else {
                loadedWorkspaceTitles.removeValue(forKey: workspaceID)
            }
        }
    }

    private func toggleRead(_ notification: TerminalNotification) {
        if notification.isRead {
            notificationStore.markUnread(id: notification.id)
        } else {
            notificationStore.markRead(id: notification.id)
            if let surfaceID = notification.surfaceId {
                notificationStore.clearFocusedReadIndicator(
                    forTabId: notification.tabId,
                    surfaceId: surfaceID
                )
            }
        }
    }

    private func open(_ notification: TerminalNotification) {
        _ = AppDelegate.shared?.openTerminalNotification(notification)
        onDismiss()
    }

    @objc private func jumpToLatestUnread(_ sender: Any?) {
        AppDelegate.shared?.jumpToLatestUnread()
        onDismiss()
    }

    @objc private func clearAll(_ sender: Any?) {
        notificationStore.clearAll()
    }
}
