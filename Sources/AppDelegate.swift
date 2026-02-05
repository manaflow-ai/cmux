import AppKit
import Bonsplit
import CoreServices
import UserNotifications
import Sentry

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation {
    static var shared: AppDelegate?

    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    weak var sidebarState: SidebarState?
    private var workspaceObserver: NSObjectProtocol?
    private var shortcutMonitor: Any?
    private let updateController = UpdateController()
    private lazy var titlebarAccessoryController = UpdateTitlebarAccessoryController(viewModel: updateViewModel)
    private let windowDecorationsController = WindowDecorationsController()
#if DEBUG
    private var didSetupJumpUnreadUITest = false
    private var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
#endif

    var updateViewModel: UpdateViewModel {
        updateController.viewModel
    }

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SentrySDK.start { options in
            options.dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
            #if DEBUG
            options.environment = "development"
            options.debug = true
            #else
            options.environment = "production"
            options.debug = false
            #endif
            options.sendDefaultPii = true
        }

        registerLaunchServicesBundle()
        enforceSingleInstance()
        NSWindow.allowsAutomaticWindowTabbing = false
        disableNativeTabbingShortcut()
        ensureApplicationIcon()
        observeDuplicateLaunches()
        configureUserNotifications()
        updateController.startUpdater()
        titlebarAccessoryController.start()
        windowDecorationsController.start()
        installShortcutMonitor()
#if DEBUG
        UpdateTestSupport.applyIfNeeded(to: updateController.viewModel)
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if UpdateTestSupport.performMockFeedCheckIfNeeded(on: self.updateController.viewModel) {
                    return
                }
                self.updateController.checkForUpdatesWhenReady()
            }
        }
#endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let tabManager, let notificationStore else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    func applicationWillTerminate(_ notification: Notification) {
        notificationStore?.clearAll()
    }

    func configure(tabManager: TabManager, notificationStore: TerminalNotificationStore, sidebarState: SidebarState) {
        self.tabManager = tabManager
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
#if DEBUG
        setupJumpUnreadUITestIfNeeded()
#endif
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateViewModel.overrideState = nil
        updateController.checkForUpdates()
    }

    #if DEBUG
    @objc func showUpdatePill(_ sender: Any?) {
        updateViewModel.overrideState = .notFound(.init(acknowledgement: {}))
    }

    @objc func showUpdatePillLoading(_ sender: Any?) {
        updateViewModel.overrideState = .checking(.init(cancel: {}))
    }

    @objc func hideUpdatePill(_ sender: Any?) {
        updateViewModel.overrideState = .idle
    }

    @objc func clearUpdatePillOverride(_ sender: Any?) {
        updateViewModel.overrideState = nil
    }
#endif

    @objc func copyUpdateLogs(_ sender: Any?) {
        let logText = UpdateLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No update logs captured.\nLog file: \(UpdateLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(UpdateLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
    @objc func copyFocusLogs(_ sender: Any?) {
        let logText = FocusLogStore.shared.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No focus logs captured.\nLog file: \(FocusLogStore.shared.logPath())"
        } else {
            payload = logText + "\nLog file: \(FocusLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

#if DEBUG
    @objc func openDebugScrollbackTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let config = GhosttyConfig.load()
        let lineCount = min(max(config.scrollbackLimit * 2, 2000), 60000)
        let command = "for i in {1..\(lineCount)}; do printf \"scrollback %06d\\n\" $i; done\n"
        sendTextWhenReady(command, to: tab)
    }

    @objc func openDebugLoremTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let lineCount = 2000
        let base = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore."
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for index in 1...lineCount {
            lines.append(String(format: "%04d %@", index, base))
        }
        let payload = lines.joined(separator: "\n") + "\n"
        sendTextWhenReady(payload, to: tab)
    }

    private func sendTextWhenReady(_ text: String, to tab: Tab, attempt: Int = 0) {
        let maxAttempts = 60
        if let terminalPanel = tab.focusedTerminalPanel, terminalPanel.surface.surface != nil {
            terminalPanel.sendText(text)
            return
        }
        guard attempt < maxAttempts else {
            NSLog("Debug scrollback: surface not ready after \(maxAttempts) attempts")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendTextWhenReady(text, to: tab, attempt: attempt + 1)
        }
    }

    @objc func triggerSentryTestCrash(_ sender: Any?) {
        SentrySDK.crash()
    }
#endif

#if DEBUG
    private func setupJumpUnreadUITestIfNeeded() {
        guard !didSetupJumpUnreadUITest else { return }
        didSetupJumpUnreadUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let tabManager, let notificationStore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let initialIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabId }) ?? 0
            let tab = tabManager.addTab()
            guard let initialPanelId = tab.focusedPanelId else { return }

            _ = tabManager.newSplit(tabId: tab.id, surfaceId: initialPanelId, direction: .right)
            guard let targetPanelId = tab.focusedPanelId else { return }
            // Find another panel that's not the currently focused one
            let otherPanelId = tab.panels.keys.first(where: { $0 != targetPanelId })
            if let otherPanelId {
                tab.focusPanel(otherPanelId)
            }

            notificationStore.addNotification(
                tabId: tab.id,
                surfaceId: targetPanelId,
                title: "JumpToUnread",
                subtitle: "",
                body: ""
            )

            self.writeJumpUnreadTestData([
                "expectedTabId": tab.id.uuidString,
                "expectedSurfaceId": targetPanelId.uuidString
            ])

            tabManager.selectTab(at: initialIndex)
        }
    }

    func recordJumpToUnreadFocus(tabId: UUID, surfaceId: UUID) {
        writeJumpUnreadTestData([
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId.uuidString
        ])
    }

    func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        jumpUnreadFocusExpectation = (tabId: tabId, surfaceId: surfaceId)
    }

    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        guard let expectation = jumpUnreadFocusExpectation else { return }
        guard expectation.tabId == tabId && expectation.surfaceId == surfaceId else { return }
        jumpUnreadFocusExpectation = nil
        recordJumpToUnreadFocus(tabId: tabId, surfaceId: surfaceId)
    }

    private func writeJumpUnreadTestData(_ updates: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        var payload = loadJumpUnreadTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadJumpUnreadTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
#endif

    func attachUpdateAccessory(to window: NSWindow) {
        titlebarAccessoryController.start()
        titlebarAccessoryController.attach(to: window)
    }

    func applyWindowDecorations(to window: NSWindow) {
        windowDecorationsController.apply(to: window)
    }

    func toggleNotificationsPopover(animated: Bool = true) {
        titlebarAccessoryController.toggleNotificationsPopover(animated: animated)
    }

    func jumpToLatestUnread() {
        guard let notificationStore, let tabManager else { return }
        guard let notification = notificationStore.notifications.first(where: { !$0.isRead }) else { return }
        tabManager.focusTabFromNotification(notification.tabId, surfaceId: notification.surfaceId)
    }

    private func installShortcutMonitor() {
        // Local monitor only receives events when app is active (not global)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleCustomShortcut(event: event) {
                return nil // Consume the event
            }
            return event // Pass through
        }
    }

    private func handleCustomShortcut(event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Check Show Notifications shortcut
        let notifShortcut = KeyboardShortcutSettings.showNotificationsShortcut()
        if matchShortcut(event: event, shortcut: notifShortcut) {
            toggleNotificationsPopover(animated: false)
            return true
        }

        // Check Jump to Unread shortcut
        let unreadShortcut = KeyboardShortcutSettings.jumpToUnreadShortcut()
        if matchShortcut(event: event, shortcut: unreadShortcut) {
            jumpToLatestUnread()
            return true
        }

        // Sidebar tab navigation: Cmd+] / Cmd+[
        let nextSidebarShortcut = KeyboardShortcutSettings.nextSidebarTabShortcut()
        if matchShortcut(event: event, shortcut: nextSidebarShortcut) {
            tabManager?.selectNextTab()
            return true
        }

        let prevSidebarShortcut = KeyboardShortcutSettings.prevSidebarTabShortcut()
        if matchShortcut(event: event, shortcut: prevSidebarShortcut) {
            tabManager?.selectPreviousTab()
            return true
        }

        // Numeric shortcuts for specific sidebar tabs: Cmd+1-9
        if flags == [.command] {
            if let num = Int(chars), num >= 1 && num <= 9 {
                tabManager?.selectTab(at: num - 1)
                return true
            }
        }

        // Pane focus navigation: Cmd+Option+Arrow
        if matchArrowShortcut(event: event, shortcut: KeyboardShortcutSettings.focusLeftShortcut(), keyCode: 123) {
            tabManager?.movePaneFocus(direction: .left)
            return true
        }
        if matchArrowShortcut(event: event, shortcut: KeyboardShortcutSettings.focusRightShortcut(), keyCode: 124) {
            tabManager?.movePaneFocus(direction: .right)
            return true
        }
        if matchArrowShortcut(event: event, shortcut: KeyboardShortcutSettings.focusUpShortcut(), keyCode: 126) {
            tabManager?.movePaneFocus(direction: .up)
            return true
        }
        if matchArrowShortcut(event: event, shortcut: KeyboardShortcutSettings.focusDownShortcut(), keyCode: 125) {
            tabManager?.movePaneFocus(direction: .down)
            return true
        }

        // Split actions: Cmd+D / Cmd+Shift+D
        let splitRightShortcut = KeyboardShortcutSettings.splitRightShortcut()
        if matchShortcut(event: event, shortcut: splitRightShortcut) {
            tabManager?.createSplit(direction: .right)
            return true
        }

        let splitDownShortcut = KeyboardShortcutSettings.splitDownShortcut()
        if matchShortcut(event: event, shortcut: splitDownShortcut) {
            tabManager?.createSplit(direction: .down)
            return true
        }

        // Bonsplit tab navigation: Ctrl+Tab / Ctrl+Shift+Tab
        if matchTabShortcut(event: event, shortcut: KeyboardShortcutSettings.nextBonsplitTabShortcut()) {
            tabManager?.selectNextBonsplitTab()
            return true
        }
        if matchTabShortcut(event: event, shortcut: KeyboardShortcutSettings.prevBonsplitTabShortcut()) {
            tabManager?.selectPreviousBonsplitTab()
            return true
        }

        // New bonsplit tab: Cmd+Shift+T
        let newBonsplitTabShortcut = KeyboardShortcutSettings.newBonsplitTabShortcut()
        if matchShortcut(event: event, shortcut: newBonsplitTabShortcut) {
            tabManager?.newBonsplitTab()
            return true
        }

        // Open browser: Cmd+Shift+B
        let openBrowserShortcut = KeyboardShortcutSettings.openBrowserShortcut()
        if matchShortcut(event: event, shortcut: openBrowserShortcut) {
            tabManager?.openBrowser()
            return true
        }

        return false
    }

    /// Match a shortcut against an event, handling normal keys
    private func matchShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return chars == shortcut.key && flags == shortcut.modifierFlags
    }

    /// Match arrow key shortcuts using keyCode
    private func matchArrowShortcut(event: NSEvent, shortcut: StoredShortcut, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == keyCode && flags == shortcut.modifierFlags
    }

    /// Match tab key shortcuts using keyCode 48
    private func matchTabShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 48 && flags == shortcut.modifierFlags
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        updateController.validateMenuItem(item)
    }


    private func configureUserNotifications() {
        let actions = [
            UNNotificationAction(
                identifier: TerminalNotificationStore.actionShowIdentifier,
                title: "Show"
            )
        ]

        let category = UNNotificationCategory(
            identifier: TerminalNotificationStore.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    private func disableNativeTabbingShortcut() {
        guard let menu = NSApp.mainMenu else { return }
        disableMenuItemShortcut(in: menu, action: #selector(NSWindow.toggleTabBar(_:)))
    }

    private func disableMenuItemShortcut(in menu: NSMenu, action: Selector) {
        for item in menu.items {
            if item.action == action {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                disableMenuItemShortcut(in: submenu, action: action)
            }
        }
    }

    private func ensureApplicationIcon() {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func registerLaunchServicesBundle() {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let registerStatus = LSRegisterURL(bundleURL as CFURL, true)
        if registerStatus != noErr {
            NSLog("LaunchServices registration failed (status: \(registerStatus)) for \(bundleURL.path)")
        }
    }

    private func enforceSingleInstance() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let currentURL = Bundle.main.bundleURL.standardizedFileURL

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            guard app.processIdentifier != currentPid else { continue }
            if let url = app.bundleURL?.standardizedFileURL, url == currentURL { continue }
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
        }
    }

    private func observeDuplicateLaunches() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let currentURL = Bundle.main.bundleURL.standardizedFileURL

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.bundleIdentifier == bundleId, app.processIdentifier != currentPid else { return }
            if let url = app.bundleURL?.standardizedFileURL, url == currentURL { return }

            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(response)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard let tabIdString = response.notification.request.content.userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString) else {
            return
        }
        let surfaceId: UUID? = {
            guard let surfaceIdString = response.notification.request.content.userInfo["surfaceId"] as? String else {
                return nil
            }
            return UUID(uuidString: surfaceIdString)
        }()

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, TerminalNotificationStore.actionShowIdentifier:
            DispatchQueue.main.async {
                self.tabManager?.focusTabFromNotification(tabId, surfaceId: surfaceId)
                self.markReadIfFocused(response: response, tabId: tabId, surfaceId: surfaceId)
            }
        case UNNotificationDismissActionIdentifier:
            DispatchQueue.main.async {
                if let notificationId = UUID(uuidString: response.notification.request.identifier) {
                    self.notificationStore?.markRead(id: notificationId)
                } else if let notificationIdString = response.notification.request.content.userInfo["notificationId"] as? String,
                          let notificationId = UUID(uuidString: notificationIdString) {
                    self.notificationStore?.markRead(id: notificationId)
                }
            }
        default:
            break
        }
    }

    private func markReadIfFocused(response: UNNotificationResponse, tabId: UUID, surfaceId: UUID?) {
        let notificationId: UUID? = {
            if let id = UUID(uuidString: response.notification.request.identifier) {
                return id
            }
            if let idString = response.notification.request.content.userInfo["notificationId"] as? String,
               let id = UUID(uuidString: idString) {
                return id
            }
            return nil
        }()

        guard let notificationId else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let tabManager = self.tabManager else { return }
            guard tabManager.selectedTabId == tabId else { return }
            if let surfaceId {
                guard tabManager.focusedSurfaceId(for: tabId) == surfaceId else { return }
            }
            self.notificationStore?.markRead(id: notificationId)
        }
    }

}
