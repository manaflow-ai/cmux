import AppKit
import Bonsplit
import Combine
import CmuxFoundation
import Observation

@MainActor
final class NotificationsPageViewController: NSViewController {
    private let notificationStore: TerminalNotificationStore
    private let tabManager: TabManager
    private var selection: () -> SidebarSelection
    private var setSelection: (SidebarSelection) -> Void

    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: String(
        localized: "notifications.title",
        defaultValue: "Notifications"
    ))
    private let jumpButton = NSButton()
    private let clearAllButton = NSButton()
    private let forwardingContainer = NSView()
    private let forwardToggle = NSButton()
    private let forwardingSubtitle = NSTextField(wrappingLabelWithString: String(
        localized: "notifications.forwardToPhone.subtitle",
        defaultValue: "Send agent notifications to the cmux iPhone app. Off by default; nothing is uploaded unless this is on."
    ))
    private let modePopup = NSPopUpButton()
    private let awayExplanationLabel = NSTextField(wrappingLabelWithString: "")
    private let hideContentToggle = NSButton()
    private let forwardingDetailStack = NSStackView()
    private let contentContainer = NSView()

    private var cancellables: Set<AnyCancellable> = []
    private var defaultsObserver: NSObjectProtocol?
    private var shortcutObservationGeneration: UInt = 0
    private weak var initiallyFocusedButton: NSButton?
    private var focusTask: Task<Void, Never>?

    init(
        notificationStore: TerminalNotificationStore,
        tabManager: TabManager,
        selection: @escaping () -> SidebarSelection,
        setSelection: @escaping (SidebarSelection) -> Void
    ) {
        self.notificationStore = notificationStore
        self.tabManager = tabManager
        self.selection = selection
        self.setSelection = setSelection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        focusTask?.cancel()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        configureHeader()
        configureForwardingControls()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let separator1 = separator()
        let separator2 = separator()
        let rootStack = NSStackView(views: [header, separator1, forwardingContainer, separator2, contentContainer])
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: root.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        view = root

        bindModels()
        observeShortcuts()
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        scheduleInitialFocus()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        focusTask?.cancel()
        focusTask = nil
    }

    func updateSelection(
        selection: @escaping () -> SidebarSelection,
        setSelection: @escaping (SidebarSelection) -> Void
    ) {
        self.selection = selection
        self.setSelection = setSelection
        if selection() == .notifications {
            scheduleInitialFocus()
        }
    }

    func teardown() {
        focusTask?.cancel()
        focusTask = nil
        shortcutObservationGeneration &+= 1
        cancellables.removeAll()
    }

    private func configureHeader() {
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        jumpButton.target = self
        jumpButton.action = #selector(jumpToLatestUnread(_:))
        jumpButton.bezelStyle = .rounded
        jumpButton.controlSize = .regular

        clearAllButton.title = String(localized: "notifications.clearAll", defaultValue: "Clear All")
        clearAllButton.target = self
        clearAllButton.action = #selector(clearAll(_:))
        clearAllButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(jumpButton)
        header.addArrangedSubview(clearAllButton)
    }

    private func configureForwardingControls() {
        forwardToggle.setButtonType(.switch)
        forwardToggle.title = String(
            localized: "notifications.forwardToPhone.title",
            defaultValue: "Forward notifications to my iPhone"
        )
        forwardToggle.target = self
        forwardToggle.action = #selector(forwardingChanged(_:))

        forwardingSubtitle.font = .systemFont(ofSize: 10)
        forwardingSubtitle.textColor = .secondaryLabelColor
        forwardingSubtitle.maximumNumberOfLines = 0

        modePopup.addItem(withTitle: String(
            localized: "notifications.forwardToPhone.mode.onlyWhenAway",
            defaultValue: "Only when away from this Mac"
        ))
        modePopup.lastItem?.tag = 0
        modePopup.addItem(withTitle: String(
            localized: "notifications.forwardToPhone.mode.always",
            defaultValue: "Always"
        ))
        modePopup.lastItem?.tag = 1
        modePopup.controlSize = .small
        modePopup.target = self
        modePopup.action = #selector(forwardingModeChanged(_:))

        awayExplanationLabel.font = .systemFont(ofSize: 10)
        awayExplanationLabel.textColor = .secondaryLabelColor
        awayExplanationLabel.maximumNumberOfLines = 0

        hideContentToggle.setButtonType(.switch)
        hideContentToggle.title = String(
            localized: "notifications.forwardToPhone.hideContent",
            defaultValue: "Hide content (send a generic message instead of the terminal text)"
        )
        hideContentToggle.font = .systemFont(ofSize: 10)
        hideContentToggle.target = self
        hideContentToggle.action = #selector(hideContentChanged(_:))

        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 8
        let modeLabel = NSTextField(labelWithString: String(
            localized: "notifications.forwardToPhone.mode.label",
            defaultValue: "When to send"
        ))
        modeLabel.font = .systemFont(ofSize: 10)
        modeRow.addArrangedSubview(modeLabel)
        modeRow.addArrangedSubview(modePopup)
        modeRow.addArrangedSubview(NSView())

        forwardingDetailStack.orientation = .vertical
        forwardingDetailStack.alignment = .leading
        forwardingDetailStack.spacing = 4
        forwardingDetailStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        forwardingDetailStack.addArrangedSubview(modeRow)
        forwardingDetailStack.addArrangedSubview(awayExplanationLabel)
        forwardingDetailStack.addArrangedSubview(hideContentToggle)

        let stack = NSStackView(views: [forwardToggle, forwardingSubtitle, forwardingDetailStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        forwardingContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: forwardingContainer.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: forwardingContainer.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: forwardingContainer.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: forwardingContainer.bottomAnchor, constant: -10),
            forwardingSubtitle.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            awayExplanationLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -20),
        ])
    }

    private func bindModels() {
        notificationStore.objectWillChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.reload()
                }
            }
            .store(in: &cancellables)
        tabManager.objectWillChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.reloadContent()
                }
            }
            .store(in: &cancellables)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateForwardingControls() }
        }
    }

    private func observeShortcuts() {
        shortcutObservationGeneration &+= 1
        let generation = shortcutObservationGeneration
        withObservationTracking {
            _ = KeyboardShortcutSettingsObserver.shared.revision
            updateJumpButton()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.shortcutObservationGeneration == generation else { return }
                self.observeShortcuts()
            }
        }
    }

    private func reload() {
        updateHeader()
        updateForwardingControls()
        reloadContent()
    }

    private func updateHeader() {
        let snapshot = notificationStore.notificationMenuSnapshot
        jumpButton.isHidden = !snapshot.hasNotifications
        clearAllButton.isHidden = !snapshot.hasNotifications
        jumpButton.isEnabled = snapshot.hasUnreadNotifications
        updateJumpButton()
    }

    private func updateJumpButton() {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
        jumpButton.title = "\(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))  \(shortcut.displayString)"
        jumpButton.toolTip = KeyboardShortcutSettings.Action.jumpToUnread.tooltip(
            String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")
        )
        jumpButton.keyEquivalent = shortcut.menuItemKeyEquivalent ?? ""
        jumpButton.keyEquivalentModifierMask = shortcut.eventModifiers
    }

    private func updateForwardingControls() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: PhonePushSettings.forwardEnabledKey)
        let hideContent = defaults.bool(forKey: PhonePushSettings.hideContentKey)
        let mode = defaults.string(forKey: PhonePushSettings.forwardModeKey)
            ?? PhoneForwardingMode.defaultMode.rawValue
        forwardToggle.state = enabled ? .on : .off
        hideContentToggle.state = hideContent ? .on : .off
        let isAlways = mode == PhoneForwardingMode.always.rawValue
        modePopup.selectItem(withTag: isAlways ? 1 : 0)
        forwardingDetailStack.isHidden = !enabled
        awayExplanationLabel.isHidden = isAlways
        awayExplanationLabel.stringValue = awayModeExplanation
    }

    private var awayModeExplanation: String {
        let format = String(
            localized: "notifications.forwardToPhone.mode.subtitle",
            defaultValue: "Away means the screen is locked or asleep, the screensaver is running, or there has been no keyboard or mouse input for %lld minutes."
        )
        return String(format: format, Int64(MacPresenceMonitor.recentHardwareInputThreshold / 60))
    }

    private func reloadContent() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        initiallyFocusedButton = nil

        let content: NSView
        if !notificationStore.notificationMenuSnapshot.hasNotifications {
            content = makeEmptyState(
                symbolName: "bell.slash",
                title: String(localized: "notifications.empty.title", defaultValue: "No notifications yet"),
                message: String(
                    localized: "notifications.empty.description",
                    defaultValue: "Desktop notifications will appear here for quick review."
                )
            )
        } else if notificationStore.notifications.isEmpty {
            content = makeEmptyState(
                symbolName: "bell.badge",
                title: notificationStore.notificationMenuSnapshot.stateHintTitle,
                message: nil
            )
        } else {
            content = makeNotificationsList()
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        scheduleInitialFocus()
    }

    private func makeNotificationsList() -> NSView {
        let tabTitles = AppDelegate.shared?.tabTitlesByTabId() ?? [:]
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        rows.translatesAutoresizingMaskIntoConstraints = false

        var previousButton: NSButton?
        for (index, notification) in notificationStore.notifications.enumerated() {
            let tabTitle = tabTitles[notification.tabId]
                ?? tabManager.tabs.first(where: { $0.id == notification.tabId })?.title
            let row = NotificationRowNativeView(
                notification: notification,
                tabTitle: tabTitle,
                onOpen: { [weak self] in
                    guard let self else { return }
                    _ = AppDelegate.shared?.openTerminalNotification(notification)
                    if notification.clickAction == nil {
                        self.setSelection(.tabs)
                    }
                },
                onClear: { [weak self] in self?.notificationStore.remove(id: notification.id) }
            )
            rows.addArrangedSubview(row)
            row.openButton.previousKeyView = previousButton
            previousButton?.nextKeyView = row.openButton
            previousButton = row.openButton
            if index == 0 {
                initiallyFocusedButton = row.openButton
                row.openButton.keyEquivalent = "\r"
            }
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = rows
        rows.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        return scrollView
    }

    private func makeEmptyState(symbolName: String, title: String, message: String?) -> NSView {
        let root = NSView()
        let image = NSImageView(image: NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        ) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 32, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.alignment = .center
        let views: [NSView]
        if let message {
            let messageLabel = NSTextField(wrappingLabelWithString: message)
            messageLabel.font = .preferredFont(forTextStyle: .subheadline)
            messageLabel.textColor = .secondaryLabelColor
            messageLabel.alignment = .center
            messageLabel.maximumNumberOfLines = 0
            views = [image, titleLabel, messageLabel]
        } else {
            views = [image, titleLabel]
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            image.widthAnchor.constraint(equalToConstant: 36),
            image.heightAnchor.constraint(equalToConstant: 36),
        ])
        return root
    }

    private func scheduleInitialFocus() {
        focusTask?.cancel()
        guard selection() == .notifications, let initiallyFocusedButton else { return }
        focusTask = Task { @MainActor [weak self, weak initiallyFocusedButton] in
            await Task.yield()
            guard let self, !Task.isCancelled,
                  self.selection() == .notifications,
                  let initiallyFocusedButton,
                  initiallyFocusedButton.window != nil
            else { return }
            initiallyFocusedButton.window?.makeFirstResponder(initiallyFocusedButton)
        }
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func jumpToLatestUnread(_ sender: NSButton) {
        AppDelegate.shared?.jumpToLatestUnread()
    }

    @objc private func clearAll(_ sender: NSButton) {
        notificationStore.clearAll()
    }

    @objc private func forwardingChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: PhonePushSettings.forwardEnabledKey)
        updateForwardingControls()
    }

    @objc private func forwardingModeChanged(_ sender: NSPopUpButton) {
        let mode: PhoneForwardingMode = sender.selectedTag() == 1 ? .always : .onlyWhenAway
        UserDefaults.standard.set(mode.rawValue, forKey: PhonePushSettings.forwardModeKey)
        updateForwardingControls()
    }

    @objc private func hideContentChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: PhonePushSettings.hideContentKey)
    }
}

@MainActor
private final class NotificationRowNativeView: NSView {
    let openButton = NSButton()
    private let onOpen: () -> Void
    private let onClear: () -> Void

    init(
        notification: TerminalNotification,
        tabTitle: String?,
        onOpen: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.onClear = onClear
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 10

        openButton.title = ""
        openButton.isBordered = false
        openButton.target = self
        openButton.action = #selector(open(_:))
        openButton.setAccessibilityIdentifier("NotificationRow.\(notification.id.uuidString)")
        openButton.setAccessibilityLabel(notification.title)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = notification.isRead
            ? NSColor.clear.cgColor
            : NSColor.controlAccentColor.cgColor
        dot.layer?.borderWidth = 1
        dot.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(
            notification.isRead ? 0.2 : 1
        ).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: notification.title)
        title.font = .preferredFont(forTextStyle: .headline)
        title.lineBreakMode = .byTruncatingTail
        let time = NSTextField(labelWithString: notification.createdAt.formatted(date: .omitted, time: .shortened))
        time.font = .preferredFont(forTextStyle: .caption1)
        time.textColor = .secondaryLabelColor
        let titleRow = NSStackView(views: [title, NSView(), time])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8

        let labels = NSStackView(views: [titleRow])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        if !notification.body.isEmpty {
            let body = NSTextField(wrappingLabelWithString: notification.body)
            body.font = .preferredFont(forTextStyle: .subheadline)
            body.textColor = .secondaryLabelColor
            body.maximumNumberOfLines = 3
            body.lineBreakMode = .byTruncatingTail
            labels.addArrangedSubview(body)
        }
        if let tabTitle {
            let tab = NSTextField(labelWithString: tabTitle)
            tab.font = .preferredFont(forTextStyle: .caption1)
            tab.textColor = .secondaryLabelColor
            labels.addArrangedSubview(tab)
        }
        labels.translatesAutoresizingMaskIntoConstraints = false
        openButton.addSubview(dot)
        openButton.addSubview(labels)

        let clear = NSButton()
        clear.title = ""
        clear.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "notifications.row.clear", defaultValue: "Clear notification")
        )
        clear.imagePosition = .imageOnly
        clear.isBordered = false
        clear.contentTintColor = .secondaryLabelColor
        clear.toolTip = String(localized: "notifications.row.clear", defaultValue: "Clear notification")
        clear.setAccessibilityLabel(clear.toolTip)
        clear.target = self
        clear.action = #selector(clear(_:))
        clear.translatesAutoresizingMaskIntoConstraints = false

        addSubview(openButton)
        addSubview(clear)
        NSLayoutConstraint.activate([
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            openButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            openButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            clear.leadingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: 6),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            clear.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            clear.widthAnchor.constraint(equalToConstant: 18),
            clear.heightAnchor.constraint(equalToConstant: 18),
            dot.leadingAnchor.constraint(equalTo: openButton.leadingAnchor),
            dot.topAnchor.constraint(equalTo: openButton.topAnchor, constant: 5),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            labels.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: -6),
            labels.topAnchor.constraint(equalTo: openButton.topAnchor),
            labels.bottomAnchor.constraint(equalTo: openButton.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func open(_ sender: NSButton) {
        onOpen()
    }

    @objc private func clear(_ sender: NSButton) {
        onClear()
    }
}
