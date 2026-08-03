import AppKit
import CmuxAppKitSupportUI
import CmuxNotifications
import CmuxTerminal
import Observation

@MainActor
final class DockPanelViewController: NSViewController {
    private struct RenderSnapshot {
        let trustRequest: DockTrustRequest?
        let errorMessage: String?
        let panelIDs: Set<UUID>
        let unreadPanelIDs: Set<UUID>
    }

    private let store: DockSplitStore
    private let unreadProjection: DockUnreadPanelProjection
    private let visibilityHostID = UUID()
    private let contentContainer = NSView()
    private let keyboardFocusView = DockKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))

    private var isSidebarVisible: Bool
    private var mode: RightSidebarMode
    private var rootDirectory: String?
    private var windowAppearance: WindowAppearanceSnapshot
    private var rightSidebarOwnsInputFocus: Bool
    private var appearanceConfig = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "dock.initial")
    private var appearanceRevision: UInt = 0
    private var splitController: DockSplitViewController?
    private weak var installedController: NSViewController?
    private var storeObservationGeneration: UInt = 0
    private var notificationTask: Task<Void, Never>?

    init(
        store: DockSplitStore,
        isSidebarVisible: Bool,
        mode: RightSidebarMode,
        rootDirectory: String?,
        windowAppearance: WindowAppearanceSnapshot,
        rightSidebarOwnsInputFocus: Bool,
        unreadSource: SidebarUnreadModel
    ) {
        self.store = store
        self.isSidebarVisible = isSidebarVisible
        self.mode = mode
        self.rootDirectory = rootDirectory
        self.windowAppearance = windowAppearance
        self.rightSidebarOwnsInputFocus = rightSidebarOwnsInputFocus
        self.unreadProjection = DockUnreadPanelProjection(
            source: unreadSource,
            workspaceID: store.workspaceId,
            panelIDs: Set(store.panels.keys),
            isActive: isSidebarVisible && mode == .dock
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        notificationTask?.cancel()
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.setAccessibilityIdentifier("DockPanel")
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        keyboardFocusView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)
        root.addSubview(keyboardFocusView)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            keyboardFocusView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            keyboardFocusView.topAnchor.constraint(equalTo: root.topAnchor),
            keyboardFocusView.widthAnchor.constraint(equalToConstant: 1),
            keyboardFocusView.heightAnchor.constraint(equalToConstant: 1),
        ])
        keyboardFocusView.focusFirstControl = { [weak store] in
            store?.focusFirstControl() == true
        }
        keyboardFocusView.ownsDockBrowserFocus = { [weak store] responder, window in
            store?.browserPanel(owning: responder, in: window) != nil
        }
        view = root
        updateBackground()
        observeAndRender()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshAppearance(reason: "viewDidAppear")
        synchronizeStoreContext()
        keyboardFocusView.registerWithKeyboardFocusCoordinatorIfNeeded()
        startNotificationTask()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        notificationTask?.cancel()
        notificationTask = nil
        store.setVisibleInUI(false, hostId: visibilityHostID)
    }

    func update(
        isSidebarVisible: Bool,
        mode: RightSidebarMode,
        rootDirectory: String?,
        windowAppearance: WindowAppearanceSnapshot,
        rightSidebarOwnsInputFocus: Bool
    ) {
        self.isSidebarVisible = isSidebarVisible
        self.mode = mode
        self.rootDirectory = rootDirectory
        self.windowAppearance = windowAppearance
        self.rightSidebarOwnsInputFocus = rightSidebarOwnsInputFocus
        synchronizeStoreContext()
        observeAndRender()
    }

    func teardown() {
        notificationTask?.cancel()
        notificationTask = nil
        storeObservationGeneration &+= 1
        store.setVisibleInUI(false, hostId: visibilityHostID)
    }

    private var appearance: PanelAppearance {
        PanelAppearance.fromConfig(appearanceConfig)
    }

    private func synchronizeStoreContext() {
        let isActive = isSidebarVisible && mode == .dock
        store.setRootDirectory(rootDirectory)
        store.setActive(
            isVisible: isSidebarVisible,
            mode: mode,
            visibilityHostId: visibilityHostID
        )
        unreadProjection.updateContext(panelIDs: Set(store.panels.keys), isActive: isActive)
    }

    private func observeAndRender() {
        storeObservationGeneration &+= 1
        let generation = storeObservationGeneration
        let snapshot = withObservationTracking {
            RenderSnapshot(
                trustRequest: store.trustRequest,
                errorMessage: store.errorMessage,
                panelIDs: Set(store.panels.keys),
                unreadPanelIDs: unreadProjection.unreadPanelIDs
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.storeObservationGeneration == generation else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                self.observeAndRender()
            }
        }
        unreadProjection.updateContext(
            panelIDs: snapshot.panelIDs,
            isActive: isSidebarVisible && mode == .dock
        )
        render(snapshot)
    }

    private func render(_ snapshot: RenderSnapshot) {
        if let trustRequest = snapshot.trustRequest {
            install(DockStateViewController(
                symbolName: "exclamationmark.shield",
                symbolColor: .systemOrange,
                title: String(localized: "dock.trust.title", defaultValue: "Trust Project Dock?"),
                message: String(
                    localized: "dock.trust.message",
                    defaultValue: "This project wants to start commands from its Dock config."
                ),
                detail: trustRequest.configPath,
                actionTitle: String(localized: "dock.trust.action", defaultValue: "Trust and Start"),
                action: { [weak store] in store?.trustAndReload() }
            ))
            return
        }

        if let errorMessage = snapshot.errorMessage {
            install(DockStateViewController(
                symbolName: "exclamationmark.triangle",
                symbolColor: .systemOrange,
                title: String(localized: "dock.error.title", defaultValue: "Dock Config Error"),
                message: errorMessage
            ))
            return
        }

        let splitController: DockSplitViewController
        if let existing = self.splitController {
            splitController = existing
            splitController.update(
                appearance: appearance,
                appearanceRevision: appearanceRevision,
                windowAppearance: windowAppearance,
                rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
                unreadPanelIDs: snapshot.unreadPanelIDs
            )
        } else {
            splitController = DockSplitViewController(
                store: store,
                appearance: appearance,
                appearanceRevision: appearanceRevision,
                windowAppearance: windowAppearance,
                rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
                unreadPanelIDs: snapshot.unreadPanelIDs
            )
            self.splitController = splitController
        }
        install(splitController)
    }

    private func install(_ controller: NSViewController) {
        guard installedController !== controller else { return }
        if let installedController {
            installedController.view.removeFromSuperview()
            installedController.removeFromParent()
        }
        addChild(controller)
        let childView = controller.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            childView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        installedController = controller
    }

    private func refreshAppearance(reason: String) {
        appearanceConfig = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "dock.\(reason)")
        appearanceRevision &+= 1
        store.applyGhosttyChrome(from: appearanceConfig)
        updateBackground()
        observeAndRender()
    }

    private func updateBackground() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = appearance.backgroundColor.cgColor
    }

    private func startNotificationTask() {
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            await withDiscardingTaskGroup { group in
                let notifications: [(Notification.Name, String)] = [
                    (.ghosttyConfigDidReload, "ghosttyConfigDidReload"),
                    (PaneChromeSettings.didChangeNotification, "paneChromeSettingsDidChange"),
                    (.ghosttyDefaultBackgroundDidChange, "ghosttyDefaultBackgroundDidChange"),
                ]
                for (name, reason) in notifications {
                    group.addTask { @MainActor [weak self] in
                        for await _ in NotificationCenter.default.notifications(named: name) {
                            guard !Task.isCancelled else { return }
                            self?.refreshAppearance(reason: reason)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private final class DockStateViewController: NSViewController {
    private let symbolName: String
    private let symbolColor: NSColor
    private let titleText: String
    private let message: String
    private let detail: String?
    private let actionTitle: String?
    private let actionHandler: (() -> Void)?

    init(
        symbolName: String,
        symbolColor: NSColor,
        title: String,
        message: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.symbolName = symbolName
        self.symbolColor = symbolColor
        self.titleText = title
        self.message = message
        self.detail = detail
        self.actionTitle = actionTitle
        self.actionHandler = action
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let image = NSImageView(image: NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: titleText
        ) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        image.contentTintColor = symbolColor

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center

        let body = NSTextField(wrappingLabelWithString: message)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.maximumNumberOfLines = 0

        let stack = NSStackView(views: [image, title, body])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.alignment = .center
            detailLabel.maximumNumberOfLines = 2
            detailLabel.lineBreakMode = .byTruncatingMiddle
            stack.addArrangedSubview(detailLabel)
        }
        if let actionTitle, let actionHandler {
            let button = DockStateActionButton(title: actionTitle, action: actionHandler)
            button.controlSize = .small
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
        ])
        view = root
    }
}

@MainActor
private final class DockStateActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(invoke(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke(_ sender: NSButton) {
        handler()
    }
}

@MainActor
final class DockKeyboardFocusView: NSView {
    var focusFirstControl: (() -> Bool)?
    var ownsDockBrowserFocus: ((NSResponder, NSWindow) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        if let window {
            AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerDockHost(self)
        }
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        if let window, ownsDockBrowserFocus?(responder, window) == true { return true }
        guard let ghosttyView = responder.cmuxStrictOwningGhosttyView(),
              let surfaceID = ghosttyView.terminalSurface?.id
        else {
            return false
        }
        return GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: surfaceID)
    }

    func focusFirstItemFromCoordinator() {
        _ = focusFirstControl?()
    }

    func focusHostFromCoordinator() -> Bool {
        focusFirstControl?() == true || window?.makeFirstResponder(self) == true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleModeShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleModeShortcut(event) {
            super.keyDown(with: event)
        }
    }

    private func handleModeShortcut(_ event: NSEvent) -> Bool {
        guard let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) else { return false }
        _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: true,
            preferredWindow: window
        )
        return true
    }
}
