import AppKit
import Bonsplit
import CMUXAgentLaunch
import Combine
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSettings
import Observation

private func rightSidebarDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}

/// Mode shown in the right sidebar (the panel toggled by its configured shortcut).
enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case find
    case sessions
    case feed
    case dock
    case customSidebar = "custom-sidebar"

    var label: String {
        switch self {
        case .files: String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .find: String(localized: "rightSidebar.mode.find", defaultValue: "Find")
        case .sessions: String(localized: "rightSidebar.mode.sessions", defaultValue: "Vault")
        case .feed: String(localized: "rightSidebar.mode.feed", defaultValue: "Feed")
        case .dock: String(localized: "rightSidebar.mode.dock", defaultValue: "Dock")
        case .customSidebar: String(localized: "rightSidebar.mode.customSidebar", defaultValue: "Custom")
        }
    }

    var symbolName: String {
        switch self {
        case .files: "folder"
        case .find: "magnifyingglass"
        case .sessions: "books.vertical"
        case .feed: "dot.radiowaves.left.and.right"
        case .dock: "dock.rectangle"
        case .customSidebar: "wand.and.stars"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .files: .switchRightSidebarToFiles
        case .find: .switchRightSidebarToFind
        case .sessions: .switchRightSidebarToSessions
        case .feed: .switchRightSidebarToFeed
        case .dock: .switchRightSidebarToDock
        case .customSidebar: nil
        }
    }

    static let paneModes: [RightSidebarMode] = [.files, .find, .sessions]

    var canOpenAsPane: Bool {
        Self.paneModes.contains(self)
    }

    static func modeShortcut(for event: NSEvent) -> RightSidebarMode? {
        modeShortcut(for: event, allowingAction: { _ in true })
    }

    static func modeShortcut(
        for event: NSEvent,
        allowingAction: (KeyboardShortcutSettings.Action) -> Bool
    ) -> RightSidebarMode? {
        guard event.type == .keyDown else { return nil }
        for mode in allCases {
            guard let action = mode.shortcutAction,
                  allowingAction(action),
                  mode.isAvailable(),
                  KeyboardShortcutSettings.shortcut(for: action).matches(event: event) else {
                continue
            }
            return mode
        }
        return nil
    }
}

enum RightSidebarContentMountPolicy {
    static func shouldMountContent(isRightSidebarVisible: Bool, hasMountedContent: Bool) -> Bool {
        isRightSidebarVisible || hasMountedContent
    }
}

enum FileExplorerRootSyncPolicy {
    static func shouldSyncFileExplorerStore(isRightSidebarVisible: Bool, mode: RightSidebarMode) -> Bool {
        guard isRightSidebarVisible else { return false }
        switch mode {
        case .files, .find:
            true
        case .sessions, .feed, .dock, .customSidebar:
            false
        }
    }
}

/// AppKit composition root for the right-sidebar chrome and native child controllers.
@MainActor
final class RightSidebarNativeViewController: NSViewController {
    private var tabManager: TabManager
    private var fileExplorerStore: FileExplorerStore
    private var fileExplorerState: FileExplorerState
    private var sessionIndexStore: SessionIndexStore
    private var titlebarHeight: CGFloat
    private var windowAppearance: WindowAppearanceSnapshot
    private var onResumeSession: ((SessionEntry) -> Void)?
    private var onOpenFilePreview: (String) -> Void
    private var onOpenAsPane: (RightSidebarMode) -> Void
    private var onClose: () -> Void

    private let modeBar = NSView()
    private let modeControls = NSStackView()
    private let contentContainer = NSView()
    private let separator = NSBox()
    private let keyboardFocusView = RightSidebarKeyboardFocusView(
        frame: NSRect(x: 0, y: 0, width: 1, height: 1)
    )
    private let modeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(
        activation: .commandOrControl
    ) { window in
        guard let responder = window.firstResponder else { return false }
        return AppDelegate.shared?.isRightSidebarFocusResponder(responder, in: window) == true
    }
    private let focusShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    private let closeShortcutHintMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)

    private var fileExplorerController: FileExplorerPanelController?
    private var sessionController: SessionIndexNativeViewController?
    private var feedController: FeedPanelNativeViewController?
    private var dockController: DockPanelViewController?
    private weak var dockStore: DockSplitStore?
    private weak var installedContentView: NSView?
    private var hasMountedContent = false
    private var feedPendingCount = 0
    private var stateCancellable: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var feedStoreInstalledObserver: NSObjectProtocol?
    private var hintObservationGeneration: UInt64 = 0
    private var feedObservationGeneration: UInt64 = 0

    init(
        tabManager: TabManager,
        fileExplorerStore: FileExplorerStore,
        fileExplorerState: FileExplorerState,
        sessionIndexStore: SessionIndexStore,
        titlebarHeight: CGFloat,
        windowAppearance: WindowAppearanceSnapshot,
        onResumeSession: ((SessionEntry) -> Void)?,
        onOpenFilePreview: @escaping (String) -> Void,
        onOpenAsPane: @escaping (RightSidebarMode) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.tabManager = tabManager
        self.fileExplorerStore = fileExplorerStore
        self.fileExplorerState = fileExplorerState
        self.sessionIndexStore = sessionIndexStore
        self.titlebarHeight = titlebarHeight
        self.windowAppearance = windowAppearance
        self.onResumeSession = onResumeSession
        self.onOpenFilePreview = onOpenFilePreview
        self.onOpenAsPane = onOpenAsPane
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        observeState()
        observeDefaults()
        observeFeedStoreInstallation()
        observeFeedPendingCount()
        observeHintInputs()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("RightSidebar")
        root.wantsLayer = true

        modeBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        keyboardFocusView.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        root.addSubview(modeBar)
        root.addSubview(separator)
        root.addSubview(contentContainer)
        root.addSubview(keyboardFocusView)
        NSLayoutConstraint.activate([
            modeBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            modeBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            modeBar.topAnchor.constraint(equalTo: root.topAnchor),
            modeBar.heightAnchor.constraint(equalToConstant: max(titlebarHeight, RightSidebarChromeMetrics.secondaryBarHeight)),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: modeBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            keyboardFocusView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            keyboardFocusView.topAnchor.constraint(equalTo: root.topAnchor),
            keyboardFocusView.widthAnchor.constraint(equalToConstant: 1),
            keyboardFocusView.heightAnchor.constraint(equalToConstant: 1),
        ])
        configureModeBar()
        view = root
        fileExplorerState.refreshModeAvailability()
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        keyboardFocusView.registerWithKeyboardFocusCoordinatorIfNeeded()
        updateShortcutHintMonitors()
        renderModeBar()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopShortcutHintMonitors()
    }

    func update(
        tabManager: TabManager,
        fileExplorerStore: FileExplorerStore,
        fileExplorerState: FileExplorerState,
        sessionIndexStore: SessionIndexStore,
        titlebarHeight: CGFloat,
        windowAppearance: WindowAppearanceSnapshot,
        onResumeSession: ((SessionEntry) -> Void)?,
        onOpenFilePreview: @escaping (String) -> Void,
        onOpenAsPane: @escaping (RightSidebarMode) -> Void,
        onClose: @escaping () -> Void
    ) {
        let stateChanged = self.fileExplorerState !== fileExplorerState
        self.tabManager = tabManager
        self.fileExplorerStore = fileExplorerStore
        self.fileExplorerState = fileExplorerState
        self.sessionIndexStore = sessionIndexStore
        self.titlebarHeight = titlebarHeight
        self.windowAppearance = windowAppearance
        self.onResumeSession = onResumeSession
        self.onOpenFilePreview = onOpenFilePreview
        self.onOpenAsPane = onOpenAsPane
        self.onClose = onClose
        if stateChanged { observeState() }
        guard isViewLoaded else { return }
        render()
    }

    func teardown() {
        stateCancellable = nil
        hintObservationGeneration &+= 1
        feedObservationGeneration &+= 1
        stopShortcutHintMonitors()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if let feedStoreInstalledObserver { NotificationCenter.default.removeObserver(feedStoreInstalledObserver) }
        defaultsObserver = nil
        feedStoreInstalledObserver = nil
        fileExplorerController?.teardown()
        sessionController?.teardown()
        feedController?.teardown()
        dockController?.teardown()
    }

    private func configureModeBar() {
        modeBar.setAccessibilityIdentifier("RightSidebarModeBar")
        let dragHandle = WindowDragHandleNSView(doubleClickBehavior: .standardAction)
        let doubleClickMonitor = TitlebarDoubleClickMonitorNSView(frame: .zero)
        for backgroundView in [doubleClickMonitor, dragHandle] {
            backgroundView.translatesAutoresizingMaskIntoConstraints = false
            modeBar.addSubview(backgroundView)
            NSLayoutConstraint.activate([
                backgroundView.leadingAnchor.constraint(equalTo: modeBar.leadingAnchor),
                backgroundView.trailingAnchor.constraint(equalTo: modeBar.trailingAnchor),
                backgroundView.topAnchor.constraint(equalTo: modeBar.topAnchor),
                backgroundView.bottomAnchor.constraint(equalTo: modeBar.bottomAnchor),
            ])
        }
        modeControls.orientation = .horizontal
        modeControls.alignment = .centerY
        modeControls.spacing = RightSidebarChromeMetrics.headerControlSpacing
        modeControls.translatesAutoresizingMaskIntoConstraints = false
        modeBar.addSubview(modeControls)
        NSLayoutConstraint.activate([
            modeControls.leadingAnchor.constraint(equalTo: modeBar.leadingAnchor, constant: 4),
            modeControls.trailingAnchor.constraint(equalTo: modeBar.trailingAnchor, constant: -6),
            modeControls.centerYAnchor.constraint(equalTo: modeBar.centerYAnchor),
        ])
        installRightSidebarChromeGeometryReporter(in: modeBar, role: .modeBar)
    }

    private func render() {
        guard isViewLoaded else { return }
        if fileExplorerState.isVisible { hasMountedContent = true }
        renderModeBar()
        updateShortcutHintMonitors()
        updateDockContext()
        guard RightSidebarContentMountPolicy.shouldMountContent(
            isRightSidebarVisible: fileExplorerState.isVisible,
            hasMountedContent: hasMountedContent
        ) else {
            installContent(nil)
            return
        }
        switch fileExplorerState.mode {
        case .files:
            installFileExplorer(presentation: .files)
        case .find:
            installFileExplorer(presentation: .find)
        case .sessions:
            installSessions()
        case .feed:
            installFeed()
        case .dock:
            installDock()
        case .customSidebar:
            installContent(nil)
        }
    }

    private func renderModeBar() {
        guard isViewLoaded else { return }
        modeBar.subviews
            .filter {
                let identifier = $0.identifier?.rawValue
                return identifier == "rightSidebarCloseShortcutHint" ||
                    identifier == "rightSidebarFocusShortcutHint"
            }
            .forEach { $0.removeFromSuperview() }
        modeControls.arrangedSubviews.forEach {
            modeControls.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let settings = ShortcutHintDebugSettings()
        let modifierHintsEnabled = settings.modifierHoldHintsEnabled
        for mode in RightSidebarMode.availableModes() {
            guard let action = mode.shortcutAction else { continue }
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            let showsHint = ShortcutHintTitlebarPolicy.shouldShow(
                shortcut: shortcut,
                alwaysShowShortcutHints: settings.alwaysShowHints,
                modifierPressed: modeShortcutHintMonitor.isModifierPressed,
                modifierHoldHintsEnabled: modifierHintsEnabled
            )
            let count = mode == .feed ? feedPendingCount : 0
            let button = RightSidebarNativeModeButton(
                mode: mode,
                pendingCount: count,
                selected: fileExplorerState.mode == mode,
                shortcut: shortcut,
                showsShortcutHint: showsHint,
                target: self,
                action: #selector(selectMode(_:))
            )
            modeControls.addArrangedSubview(button)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            installRightSidebarChromeGeometryReporter(
                in: button,
                role: .named("rightSidebarModeControl_\(mode.rawValue)")
            )
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modeControls.addArrangedSubview(spacer)
        if fileExplorerState.mode.canOpenAsPane {
            modeControls.addArrangedSubview(makeOpenAsPaneButton())
        }
        let close = makeCloseButton()
        modeControls.addArrangedSubview(close)
        installCloseShortcutHint(on: close, settings: settings)
        installFocusShortcutHint(settings: settings)
    }

    private func makeOpenAsPaneButton() -> NSButton {
        let mode = fileExplorerState.mode
        let label = String.localizedStringWithFormat(
            String(localized: "rightSidebar.openAsPane.accessibilityLabel", defaultValue: "Open %@ as Pane"),
            mode.label
        )
        let button = nativeHeaderButton(
            symbolName: "rectangle.split.2x1",
            accessibilityLabel: label,
            identifier: "RightSidebar.openAsPaneButton",
            action: #selector(openAsPane)
        )
        button.toolTip = String(localized: "rightSidebar.openAsPane.tooltip", defaultValue: "Open as pane")
        installRightSidebarChromeGeometryReporter(in: button, role: .named("rightSidebarHeaderOpenAsPane"))
        return button
    }

    private func makeCloseButton() -> NSButton {
        let button = nativeHeaderButton(
            symbolName: "xmark",
            accessibilityLabel: String(
                localized: "rightSidebar.close.accessibilityLabel",
                defaultValue: "Close Right Sidebar"
            ),
            identifier: "RightSidebar.closeButton",
            action: #selector(closeSidebar)
        )
        button.toolTip = KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
            String(localized: "rightSidebar.toggle.tooltip", defaultValue: "Toggle right sidebar")
        )
        installRightSidebarChromeGeometryReporter(in: button, role: .named("rightSidebarHeaderClose"))
        return button
    }

    private func nativeHeaderButton(
        symbolName: String,
        accessibilityLabel: String,
        identifier: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.headerControlSize),
            button.heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.headerControlSize),
        ])
        return button
    }

    private func installCloseShortcutHint(on button: NSButton, settings: ShortcutHintDebugSettings) {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .toggleRightSidebar)
        let visible = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: settings.alwaysShowHints,
            modifierPressed: closeShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: settings.modifierHoldHintsEnabled
        )
        guard visible else { return }
        let pill = makeHintPill(
            shortcut: shortcut,
            identifier: "rightSidebarCloseShortcutHint",
            emphasis: 1.05
        )
        modeBar.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(
                equalTo: button.centerXAnchor,
                constant: CGFloat(ShortcutHintDebugSettings.clamped(ShortcutHintDebugSettings.defaultRightSidebarCloseHintX))
            ),
            pill.topAnchor.constraint(
                equalTo: modeBar.topAnchor,
                constant: 3 + CGFloat(ShortcutHintDebugSettings.clamped(ShortcutHintDebugSettings.defaultRightSidebarCloseHintY))
            ),
        ])
    }

    private func installFocusShortcutHint(settings: ShortcutHintDebugSettings) {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .focusRightSidebar)
        let visible = ShortcutHintTitlebarPolicy.shouldShow(
            shortcut: shortcut,
            alwaysShowShortcutHints: settings.alwaysShowHints,
            modifierPressed: focusShortcutHintMonitor.isModifierPressed,
            modifierHoldHintsEnabled: settings.modifierHoldHintsEnabled
        )
        guard visible else { return }
        let pill = makeHintPill(
            shortcut: shortcut,
            identifier: "rightSidebarFocusShortcutHint",
            emphasis: 1.05
        )
        modeBar.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(
                equalTo: modeBar.leadingAnchor,
                constant: 6 + CGFloat(ShortcutHintDebugSettings.clamped(ShortcutHintDebugSettings.defaultRightSidebarFocusHintX))
            ),
            pill.topAnchor.constraint(
                equalTo: modeBar.topAnchor,
                constant: 5 + CGFloat(ShortcutHintDebugSettings.clamped(ShortcutHintDebugSettings.defaultRightSidebarFocusHintY))
            ),
        ])
    }

    private func makeHintPill(
        shortcut: StoredShortcut,
        identifier: String,
        emphasis: Double
    ) -> SidebarShortcutHintPillView {
        let pill = SidebarShortcutHintPillView()
        pill.configure(text: shortcut.displayString, fontSize: 9, emphasis: emphasis)
        pill.identifier = NSUserInterfaceItemIdentifier(identifier)
        pill.setAccessibilityElement(true)
        pill.setAccessibilityRole(.staticText)
        pill.setAccessibilityIdentifier(identifier)
        pill.translatesAutoresizingMaskIntoConstraints = false
        let size = pill.fittingPillSize()
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: size.width),
            pill.heightAnchor.constraint(equalToConstant: size.height),
        ])
        return pill
    }

    private func installFileExplorer(presentation: FileExplorerPanelPresentation) {
        let controller: FileExplorerPanelController
        if let fileExplorerController {
            controller = fileExplorerController
            controller.update(
                store: fileExplorerStore,
                state: fileExplorerState,
                onOpenFilePreview: onOpenFilePreview,
                presentation: presentation,
                placement: .rightSidebar,
                onFocus: nil,
                onContainerChange: nil
            )
        } else {
            controller = FileExplorerPanelController(
                store: fileExplorerStore,
                state: fileExplorerState,
                onOpenFilePreview: onOpenFilePreview,
                presentation: presentation,
                placement: .rightSidebar,
                onFocus: nil,
                onContainerChange: nil
            )
            fileExplorerController = controller
        }
        installContent(controller.containerView)
    }

    private func installSessions() {
        let controller: SessionIndexNativeViewController
        if let sessionController {
            controller = sessionController
            controller.update(store: sessionIndexStore, onResume: onResumeSession)
        } else {
            controller = SessionIndexNativeViewController(store: sessionIndexStore, onResume: onResumeSession)
            sessionController = controller
            addChild(controller)
        }
        if sessionIndexStore.entries.isEmpty, !sessionIndexStore.isLoading {
            sessionIndexStore.reload()
        }
        installContent(controller.view)
    }

    private func installFeed() {
        let controller: FeedPanelNativeViewController
        if let feedController {
            controller = feedController
        } else {
            controller = FeedPanelNativeViewController()
            feedController = controller
            addChild(controller)
        }
        installContent(controller.view)
    }

    private func installDock() {
        guard let store = AppDelegate.shared?.windowDock(for: tabManager) else {
            installContent(nil)
            return
        }
        let controller: DockPanelViewController
        if let dockController, dockStore === store {
            controller = dockController
        } else {
            dockController?.teardown()
            dockController?.removeFromParent()
            controller = DockPanelViewController(
                store: store,
                isSidebarVisible: fileExplorerState.isVisible,
                mode: fileExplorerState.mode,
                rootDirectory: nil,
                windowAppearance: windowAppearance,
                rightSidebarOwnsInputFocus: fileExplorerState.rightSidebarOwnsInputFocus,
                unreadSource: TerminalNotificationStore.shared.sidebarUnread
            )
            dockController = controller
            dockStore = store
            addChild(controller)
        }
        controller.update(
            isSidebarVisible: fileExplorerState.isVisible,
            mode: fileExplorerState.mode,
            rootDirectory: nil,
            windowAppearance: windowAppearance,
            rightSidebarOwnsInputFocus: fileExplorerState.rightSidebarOwnsInputFocus
        )
        installContent(controller.view)
    }

    private func updateDockContext() {
        dockController?.update(
            isSidebarVisible: fileExplorerState.isVisible,
            mode: fileExplorerState.mode,
            rootDirectory: nil,
            windowAppearance: windowAppearance,
            rightSidebarOwnsInputFocus: fileExplorerState.rightSidebarOwnsInputFocus
        )
    }

    private func installContent(_ content: NSView?) {
        guard installedContentView !== content else { return }
        installedContentView?.removeFromSuperview()
        installedContentView = content
        guard let content else { return }
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    @objc private func selectMode(_ sender: RightSidebarNativeModeButton) {
        let mode = sender.mode
        if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: mode,
            focusFirstItem: true,
            preferredWindow: view.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        ) != true {
            fileExplorerState.mode = mode
            render()
        }
    }

    @objc private func openAsPane() {
        onOpenAsPane(fileExplorerState.mode)
    }

    @objc private func closeSidebar() {
#if DEBUG
        cmuxDebugLog("rightSidebar.closeButton")
#endif
        onClose()
    }

    private func observeState() {
        stateCancellable = fileExplorerState.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.render()
            }
        }
    }

    private func observeDefaults() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousMode = self.fileExplorerState.mode
                self.fileExplorerState.refreshModeAvailability()
                self.updateShortcutHintMonitors()
                self.render()
                guard previousMode != self.fileExplorerState.mode,
                      self.fileExplorerState.isVisible,
                      let window = self.view.window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
                _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                    mode: self.fileExplorerState.mode,
                    focusFirstItem: false,
                    preferredWindow: window
                )
            }
        }
    }

    private func observeFeedStoreInstallation() {
        feedStoreInstalledObserver = NotificationCenter.default.addObserver(
            forName: FeedCoordinator.storeInstalledNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.observeFeedPendingCount() }
        }
    }

    private func observeFeedPendingCount() {
        feedObservationGeneration &+= 1
        let generation = feedObservationGeneration
        guard let store = FeedCoordinator.shared.store else {
            feedPendingCount = 0
            if isViewLoaded { renderModeBar() }
            return
        }
        let count = withObservationTracking {
            store.pending.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.feedObservationGeneration == generation else { return }
                await Task.yield()
                self.observeFeedPendingCount()
            }
        }
        if count != feedPendingCount {
            feedPendingCount = count
            if isViewLoaded { renderModeBar() }
        }
    }

    private func observeHintInputs() {
        hintObservationGeneration &+= 1
        let generation = hintObservationGeneration
        withObservationTracking {
            _ = modeShortcutHintMonitor.isModifierPressed
            _ = focusShortcutHintMonitor.isModifierPressed
            _ = closeShortcutHintMonitor.isModifierPressed
            _ = KeyboardShortcutSettingsObserver.shared.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.hintObservationGeneration == generation else { return }
                await Task.yield()
                self.observeHintInputs()
                if self.isViewLoaded { self.renderModeBar() }
            }
        }
    }

    private func updateShortcutHintMonitors() {
        guard isViewLoaded else { return }
        let enabled = ShortcutHintDebugSettings().modifierHoldHintsEnabled && fileExplorerState.isVisible
        let window = enabled ? view.window : nil
        modeShortcutHintMonitor.setHostWindow(window)
        focusShortcutHintMonitor.setHostWindow(window)
        closeShortcutHintMonitor.setHostWindow(window)
        if enabled {
            modeShortcutHintMonitor.start()
            focusShortcutHintMonitor.start()
            closeShortcutHintMonitor.start()
        } else {
            stopShortcutHintMonitors()
        }
    }

    private func stopShortcutHintMonitors() {
        modeShortcutHintMonitor.stop()
        focusShortcutHintMonitor.stop()
        closeShortcutHintMonitor.stop()
    }
}

@MainActor
private final class RightSidebarNativeModeButton: NSButton {
    let mode: RightSidebarMode

    init(
        mode: RightSidebarMode,
        pendingCount: Int,
        selected: Bool,
        shortcut: StoredShortcut,
        showsShortcutHint: Bool,
        target: AnyObject?,
        action: Selector
    ) {
        self.mode = mode
        super.init(frame: .zero)
        self.target = target
        self.action = action
        let countText = pendingCount > 9 ? "9+" : String(pendingCount)
        title = pendingCount > 0 ? "\(mode.label)  \(countText)" : mode.label
        image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.label)
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        bezelStyle = .regularSquare
        controlSize = .small
        font = .systemFont(ofSize: RightSidebarChromeControlStyle.labelSize, weight: .regular)
        contentTintColor = selected ? .labelColor : .secondaryLabelColor
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = RightSidebarChromeMetrics.controlCornerRadius
        layer?.backgroundColor = selected
            ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        cell?.lineBreakMode = .byTruncatingTail
        toolTip = pendingCount > 0
            ? String(
                localized: "rightSidebar.mode.pendingHelp",
                defaultValue: "\(mode.label) · \(pendingCount) pending"
            )
            : mode.label
        let accessibilityLabel = pendingCount > 0
            ? String.localizedStringWithFormat(
                String(localized: "rightSidebar.mode.pendingHelp", defaultValue: "%@ · %lld pending"),
                mode.label,
                pendingCount
            )
            : mode.label
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityIdentifier("RightSidebarModeButton.\(mode.rawValue)")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.controlHeight).isActive = true

        if showsShortcutHint {
            let pill = SidebarShortcutHintPillView()
            pill.configure(
                text: shortcut.displayString,
                fontSize: 9,
                emphasis: selected ? 1.15 : 0.95
            )
            let identifier = "rightSidebarModeShortcutHint.\(mode.rawValue)"
            pill.identifier = NSUserInterfaceItemIdentifier(identifier)
            pill.setAccessibilityElement(true)
            pill.setAccessibilityRole(.staticText)
            pill.setAccessibilityIdentifier(identifier)
            pill.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pill)
            let size = pill.fittingPillSize()
            NSLayoutConstraint.activate([
                pill.widthAnchor.constraint(equalToConstant: size.width),
                pill.heightAnchor.constraint(equalToConstant: size.height),
                pill.centerYAnchor.constraint(equalTo: centerYAnchor),
                pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 5),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class RightSidebarKeyboardFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithKeyboardFocusCoordinatorIfNeeded()
#if DEBUG
        if let window {
            dlog(
                "rs.focus.host.attach win=\(window.windowNumber) " +
                    "canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
                    "fr=\(rightSidebarDebugResponder(window.firstResponder))"
            )
        }
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerRightSidebarHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }
        if event.keyCode == 53 {
            if let window,
               AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else {
#if DEBUG
            dlog("rs.focus.host.focus result=0 reason=noWindow")
#endif
            return false
        }
        let result = window.makeFirstResponder(self)
#if DEBUG
        dlog(
            "rs.focus.host.focus result=\(result ? 1 : 0) win=\(window.windowNumber) " +
                "fr=\(rightSidebarDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }
}

extension NSView {
    var cmuxCanAcceptRightSidebarKeyboardFocus: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        var view: NSView? = self
        while let current = view {
            if current.bounds.width <= 0.5 || current.bounds.height <= 0.5 {
                return false
            }
            view = current.superview
        }
        return true
    }
}
