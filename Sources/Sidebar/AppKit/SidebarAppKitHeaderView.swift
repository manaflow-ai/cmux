import AppKit
import CmuxFoundation
import Foundation

/// Native titlebar-height header for the default AppKit workspace sidebar.
///
/// The control hierarchy is permanent. Callers replace the small state value
/// and action bundle as live window state changes; buttons always dispatch
/// through the latest bundle rather than retaining per-update closures.
@MainActor
final class SidebarAppKitHeaderView: NSView {
    nonisolated enum Control: Int, CaseIterable, Sendable {
        case toggleSidebar
        case showNotifications
        case newWorkspace
        case cloudVM
        case focusHistoryBack
        case focusHistoryForward

        var accessibilityIdentifier: String {
            switch self {
            case .toggleSidebar:
                "titlebarControl.toggleSidebar"
            case .showNotifications:
                "titlebarControl.showNotifications"
            case .newWorkspace:
                "titlebarControl.newTab"
            case .cloudVM:
                "titlebarControl.cloudVM"
            case .focusHistoryBack:
                "titlebarControl.focusHistoryBack"
            case .focusHistoryForward:
                "titlebarControl.focusHistoryForward"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .toggleSidebar:
                String(
                    localized: "titlebar.sidebar.accessibilityLabel",
                    defaultValue: "Toggle Sidebar"
                )
            case .showNotifications:
                String(
                    localized: "titlebar.notifications.accessibilityLabel",
                    defaultValue: "Notifications"
                )
            case .newWorkspace:
                String(
                    localized: "titlebar.newWorkspace.accessibilityLabel",
                    defaultValue: "New Workspace"
                )
            case .cloudVM:
                String(
                    localized: "titlebar.cloudVM.accessibilityLabel",
                    defaultValue: "cloud VM"
                )
            case .focusHistoryBack:
                String(localized: "menu.history.focusBack", defaultValue: "Focus Back")
            case .focusHistoryForward:
                String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")
            }
        }

        var acceptsContextMenu: Bool {
            self != .showNotifications
        }
    }

    nonisolated struct State: Equatable, Sendable {
        var canNavigateBack: Bool
        var canNavigateForward: Bool
        var unreadNotificationCount: Int
        var isNotificationsPresented: Bool
        var showsControls: Bool

        init(
            canNavigateBack: Bool,
            canNavigateForward: Bool,
            unreadNotificationCount: Int,
            isNotificationsPresented: Bool = false,
            showsControls: Bool = true
        ) {
            self.canNavigateBack = canNavigateBack
            self.canNavigateForward = canNavigateForward
            self.unreadNotificationCount = max(0, unreadNotificationCount)
            self.isNotificationsPresented = isNotificationsPresented
            self.showsControls = showsControls
        }

        static let empty = Self(
            canNavigateBack: false,
            canNavigateForward: false,
            unreadNotificationCount: 0
        )
    }

    struct Actions {
        var onToggleSidebar: () -> Void
        var onToggleNotifications: (NSView) -> Void
        var onNewWorkspace: () -> Void
        var onCloudVM: (NSView) -> Void
        var onFocusHistoryBack: () -> Void
        var onFocusHistoryForward: () -> Void
        var onContextMenu: ((Control, NSView, NSEvent) -> Void)?

        init(
            onToggleSidebar: @escaping () -> Void,
            onToggleNotifications: @escaping (NSView) -> Void,
            onNewWorkspace: @escaping () -> Void,
            onCloudVM: @escaping (NSView) -> Void,
            onFocusHistoryBack: @escaping () -> Void,
            onFocusHistoryForward: @escaping () -> Void,
            onContextMenu: ((Control, NSView, NSEvent) -> Void)? = nil
        ) {
            self.onToggleSidebar = onToggleSidebar
            self.onToggleNotifications = onToggleNotifications
            self.onNewWorkspace = onNewWorkspace
            self.onCloudVM = onCloudVM
            self.onFocusHistoryBack = onFocusHistoryBack
            self.onFocusHistoryForward = onFocusHistoryForward
            self.onContextMenu = onContextMenu
        }

        static let none = Self(
            onToggleSidebar: {},
            onToggleNotifications: { _ in },
            onNewWorkspace: {},
            onCloudVM: { _ in },
            onFocusHistoryBack: {},
            onFocusHistoryForward: {}
        )
    }

    private enum Metrics {
        static let baseHeight = WindowChromeMetrics.appTitlebarHeight
        static let leadingInset = HeaderChromeControlMetrics.titlebarControlsLeadingPadding
        static let trailingInset: CGFloat = 4
        static let baseButtonSide = HeaderChromeControlMetrics.buttonSize
        static let baseIconSize = HeaderChromeControlMetrics.iconSize
        static let spacing: CGFloat = 6
        static let baseBadgeSide: CGFloat = 12

        static var iconSize: CGFloat {
            GlobalFontMagnification.scaledSize(baseIconSize)
        }

        static var buttonSide: CGFloat {
            max(
                baseButtonSide,
                HeaderChromeControlMetrics.iconFrameSize(forIconSize: iconSize)
            )
        }

        static var height: CGFloat {
            let baseVerticalInsets = baseHeight - baseButtonSide
            return max(baseHeight, buttonSide + baseVerticalInsets)
        }

        static var badgeSide: CGFloat {
            GlobalFontMagnification.scaledSize(baseBadgeSide)
        }
    }

    private let controlsStack = NSStackView()
    private let toggleSidebarButton = HeaderButton(control: .toggleSidebar)
    private let notificationsButton = HeaderButton(control: .showNotifications)
    private let newWorkspaceButton = HeaderButton(control: .newWorkspace)
    private let cloudVMButton = HeaderButton(control: .cloudVM)
    private let focusBackButton = HeaderButton(control: .focusHistoryBack)
    private let focusForwardButton = HeaderButton(control: .focusHistoryForward)
    private let notificationBadge = SidebarAppKitBadgeView()
    private var buttonsByControl: [Control: HeaderButton] = [:]
    private var buttonSizeConstraints: [NSLayoutConstraint] = []
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    private var state = State.empty
    private var actions = Actions.none
    private var isPointerInside = false
    private var pointerTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpHierarchy()
        setUpAccessibility()
        applyState()
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.refreshFontMagnification()
        }
    }

    convenience init(state: State, actions: Actions) {
        self.init(frame: .zero)
        configure(state: state, actions: actions)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let controlsWidth = CGFloat(Control.allCases.count) * Metrics.buttonSide
            + CGFloat(Control.allCases.count - 1) * Metrics.spacing
        return NSSize(
            width: Metrics.leadingInset + controlsWidth + Metrics.trailingInset,
            height: Metrics.height
        )
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Replaces both current presentation state and every live callback.
    func configure(state: State, actions: Actions) {
        self.actions = actions
        update(state: state)
    }

    /// Updates availability, unread count, and notification presentation.
    func update(state: State) {
        self.state = State(
            canNavigateBack: state.canNavigateBack,
            canNavigateForward: state.canNavigateForward,
            unreadNotificationCount: state.unreadNotificationCount,
            isNotificationsPresented: state.isNotificationsPresented,
            showsControls: state.showsControls
        )
        applyState()
    }

    /// Replaces callbacks without rebuilding or reconfiguring the controls.
    func update(actions: Actions) {
        self.actions = actions
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            let result = handleTitlebarDoubleClick(
                window: window,
                behavior: .standardAction
            )
            if result.consumesEvent {
                return
            }
        }

        guard !isWindowDragSuppressed(window: window) else { return }
        if let window {
            withTemporaryWindowMovableEnabled(window: window) {
                window.performDrag(with: event)
            }
        } else {
            super.mouseDown(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for button in buttonsByControl.values {
            button.refreshAppearance()
        }
        applyNotificationBadge()
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        applyControlsVisibility()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        applyControlsVisibility()
        super.mouseExited(with: event)
    }

    private func setUpHierarchy() {
        wantsLayer = true
        setAccessibilityElement(false)

        buttonsByControl = [
            .toggleSidebar: toggleSidebarButton,
            .showNotifications: notificationsButton,
            .newWorkspace: newWorkspaceButton,
            .cloudVM: cloudVMButton,
            .focusHistoryBack: focusBackButton,
            .focusHistoryForward: focusForwardButton,
        ]

        configureButton(toggleSidebarButton, symbol: "sidebar.left", weight: .regular)
        configureButton(notificationsButton, symbol: "bell", weight: .regular)
        configureButton(newWorkspaceButton, symbol: "plus", weight: .medium)
        configureButton(cloudVMButton, symbol: "chevron.down", weight: .medium)
        configureButton(focusBackButton, symbol: "arrow.left", weight: .regular)
        configureButton(focusForwardButton, symbol: "arrow.right", weight: .regular)

        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.distribution = .fill
        controlsStack.spacing = Metrics.spacing
        addSubview(controlsStack)
        for control in Control.allCases {
            guard let button = buttonsByControl[control] else { continue }
            controlsStack.addArrangedSubview(button)
            buttonSizeConstraints.append(
                button.widthAnchor.constraint(equalToConstant: Metrics.buttonSide)
            )
            buttonSizeConstraints.append(
                button.heightAnchor.constraint(equalToConstant: Metrics.buttonSide)
            )
        }
        NSLayoutConstraint.activate(buttonSizeConstraints)

        notificationBadge.setAccessibilityElement(false)
        notificationsButton.addSubview(notificationBadge)

        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.leadingInset),
            controlsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            controlsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.trailingInset),
            notificationBadge.topAnchor.constraint(equalTo: notificationsButton.topAnchor),
            notificationBadge.trailingAnchor.constraint(equalTo: notificationsButton.trailingAnchor),
        ])

        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    private func configureButton(
        _ button: HeaderButton,
        symbol: String,
        weight: NSFont.Weight
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.focusRingType = .none
        button.imagePosition = .imageOnly
        button.configureSymbol(named: symbol, weight: weight)
        button.target = self
        button.action = #selector(controlPressed(_:))
        button.tag = button.control.rawValue
        button.onRightMouseDown = { [weak self, weak button] event in
            guard let self, let button else { return }
            handleContextMenu(for: button.control, anchor: button, event: event)
        }
    }

    private func setUpAccessibility() {
        setAccessibilityIdentifier("SidebarAppKitHeader")
        for (control, button) in buttonsByControl {
            button.identifier = NSUserInterfaceItemIdentifier(control.accessibilityIdentifier)
            button.setAccessibilityIdentifier(control.accessibilityIdentifier)
            button.setAccessibilityLabel(control.accessibilityLabel)
            button.setAccessibilityRole(.button)
        }
        refreshTooltips()
    }

    private func refreshTooltips() {
        toggleSidebarButton.toolTip = KeyboardShortcutSettings.Action.toggleSidebar.tooltip(
            String(
                localized: "titlebar.sidebar.tooltip",
                defaultValue: "Show or hide the sidebar"
            )
        )
        notificationsButton.toolTip = KeyboardShortcutSettings.Action.showNotifications.tooltip(
            String(
                localized: "titlebar.notifications.tooltip",
                defaultValue: "Show notifications"
            )
        )
        newWorkspaceButton.toolTip = KeyboardShortcutSettings.Action.newTab.tooltip(
            String(
                localized: "titlebar.newWorkspace.tooltip",
                defaultValue: "New workspace"
            )
        )
        cloudVMButton.toolTip = String(
            localized: "titlebar.cloudVM.menu.accessibilityLabel",
            defaultValue: "Cloud VM Menu"
        )
        focusBackButton.toolTip = KeyboardShortcutSettings.Action.focusHistoryBack.tooltip(
            String(localized: "menu.history.focusBack", defaultValue: "Focus Back")
        )
        focusForwardButton.toolTip = KeyboardShortcutSettings.Action.focusHistoryForward.tooltip(
            String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")
        )
    }

    private func applyState() {
        focusBackButton.isEnabled = state.canNavigateBack
        focusForwardButton.isEnabled = state.canNavigateForward
        notificationsButton.isActive = state.isNotificationsPresented
        applyNotificationBadge()
        applyControlsVisibility()
    }

    private func applyControlsVisibility() {
        let isVisible = state.showsControls
            && (isPointerInside || state.isNotificationsPresented)
        controlsStack.isHidden = !isVisible
        controlsStack.alphaValue = isVisible ? 1 : 0
    }

    private func applyNotificationBadge() {
        guard state.unreadNotificationCount > 0 else {
            notificationBadge.resetForReuse()
            return
        }
        notificationBadge.configure(
            count: min(state.unreadNotificationCount, 99),
            fillColor: cmuxAccentNSColor(for: effectiveAppearance),
            textColor: .white,
            font: GlobalFontMagnification.systemFont(ofSize: 8, weight: .semibold),
            height: Metrics.badgeSide
        )
    }

    private func refreshFontMagnification() {
        for constraint in buttonSizeConstraints {
            constraint.constant = Metrics.buttonSide
        }
        for button in buttonsByControl.values {
            button.refreshSymbolConfiguration()
        }
        applyNotificationBadge()
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    @objc private func controlPressed(_ sender: NSButton) {
        guard let control = Control(rawValue: sender.tag) else { return }
        switch control {
        case .toggleSidebar:
            actions.onToggleSidebar()
        case .showNotifications:
            actions.onToggleNotifications(sender)
        case .newWorkspace:
            actions.onNewWorkspace()
        case .cloudVM:
            actions.onCloudVM(sender)
        case .focusHistoryBack:
            guard state.canNavigateBack else { return }
            actions.onFocusHistoryBack()
        case .focusHistoryForward:
            guard state.canNavigateForward else { return }
            actions.onFocusHistoryForward()
        }
    }

    private func handleContextMenu(
        for control: Control,
        anchor: NSView,
        event: NSEvent
    ) {
        guard control.acceptsContextMenu else { return }
        actions.onContextMenu?(control, anchor, event)
    }

    /// Titlebar-style icon button with native hover/active chrome.
    private final class HeaderButton: NSButton {
        let control: Control
        var onRightMouseDown: ((NSEvent) -> Void)?
        var isActive = false {
            didSet { refreshAppearance() }
        }

        private var isPointerInside = false
        private var pointerTrackingArea: NSTrackingArea?
        private var symbolWeight: NSFont.Weight = .regular

        init(control: Control) {
            self.control = control
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = HeaderChromeControlMetrics.cornerRadius
            layer?.masksToBounds = false
            refreshAppearance()
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override var isEnabled: Bool {
            didSet { refreshAppearance() }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func updateTrackingAreas() {
            if let pointerTrackingArea {
                removeTrackingArea(pointerTrackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            pointerTrackingArea = area
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            isPointerInside = true
            refreshAppearance()
        }

        override func mouseExited(with event: NSEvent) {
            isPointerInside = false
            refreshAppearance()
        }

        override func rightMouseDown(with event: NSEvent) {
            guard control.acceptsContextMenu else {
                super.rightMouseDown(with: event)
                return
            }
            onRightMouseDown?(event)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refreshAppearance()
        }

        func configureSymbol(named symbolName: String, weight: NSFont.Weight) {
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            symbolWeight = weight
            refreshSymbolConfiguration()
        }

        func refreshSymbolConfiguration() {
            symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: Metrics.iconSize,
                weight: symbolWeight
            )
        }

        func refreshAppearance() {
            let foregroundAlpha: CGFloat
            if !isEnabled {
                foregroundAlpha = 0.34
            } else if isPointerInside || isActive {
                foregroundAlpha = 0.96
            } else {
                foregroundAlpha = 0.86
            }
            contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(foregroundAlpha)

            let backgroundAlpha: CGFloat
            if isActive {
                backgroundAlpha = 0.14
            } else if isEnabled && isPointerInside {
                backgroundAlpha = 0.07
            } else {
                backgroundAlpha = 0
            }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.secondaryLabelColor
                    .withAlphaComponent(backgroundAlpha)
                    .usingColorSpace(.deviceRGB)?.cgColor
            }
        }
    }
}
