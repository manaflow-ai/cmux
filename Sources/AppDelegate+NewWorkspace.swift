import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - New window, workspace, and welcome workspace actions
extension AppDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "")
        let newWindowItem = NSMenuItem(
            title: String(localized: "menu.file.newWindow", defaultValue: "New Window"),
            action: #selector(openNewMainWindow(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)
        return menu
    }

    @objc func openNewMainWindow(_ sender: Any?) {
        _ = createMainWindow(sourceWindow: preferredSourceWindowForNewMainWindow(sender: sender))
    }

    func openNewMainWindow(preferredWindow: NSWindow?) {
        _ = createMainWindow(sourceWindow: preferredWindow)
    }

    private func preferredSourceWindowForNewMainWindow(sender: Any?) -> NSWindow? {
        if let window = sender as? NSWindow, isMainTerminalWindow(window) {
            return window
        }
        if let event = currentKeyboardShortcutEvent(),
           let window = mainWindowForShortcutEvent(event) {
            return window
        }
        if let keyWindow = NSApp.keyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        if let context = preferredRegisteredMainWindowContext(),
           let window = resolvedWindow(for: context) {
            return window
        }
        return nil
    }

    func scheduleInitialMainWindowBootstrap(debugSource: String) {
        guard !didScheduleInitialMainWindowBootstrap else { return }
        didScheduleInitialMainWindowBootstrap = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.shouldDeferInitialMainWindowBootstrapForExternalConfirmation { self.didScheduleInitialMainWindowBootstrap = false; return }
            self.bootstrapInitialMainWindowIfNeeded(debugSource: debugSource)
        }
    }

    @discardableResult
    func bootstrapInitialMainWindowIfNeeded(
        debugSource: String,
        shouldActivate: Bool = true,
        suppressWelcome: Bool = false
    ) -> UUID {
        reserveInitialSocketPathIfNeeded()
        let windowId = ensureInitialMainWindowIfNeeded(
            shouldActivate: shouldActivate,
            suppressWelcome: suppressWelcome
        )
        if let manager = tabManagerFor(windowId: windowId)
            ?? mainWindowContexts.values.first(where: { $0.windowId == windowId })?.tabManager
            ?? preferredRegisteredMainWindowContext()?.tabManager
            ?? mainWindowContexts.values.first?.tabManager {
            startSocketListenerIfEnabled(
                tabManager: manager,
                source: "bootstrapInitialMainWindow.\(debugSource)"
            )
            MobileHostService.shared.start()
        }
        guard !didBootstrapInitialMainWindow else { return windowId }

        didBootstrapInitialMainWindow = true
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_SHOW_SETTINGS"] == "1" {
            openPreferencesWindow(debugSource: "uiTestShowSettings.\(debugSource)")
        }
        return windowId
    }

    @discardableResult
    func ensureInitialMainWindowIfNeeded(
        shouldActivate: Bool = true,
        suppressWelcome: Bool = false
    ) -> UUID {
        for context in sortedMainWindowContextsForSessionSnapshot() {
            guard let window = resolvedWindow(for: context) else { continue }
            if shouldActivate {
                mainWindowVisibilityController.focus(
                    window,
                    reason: .ensureInitialWindow,
                    activation: .none,
                    respectActivationSuppression: false
                )
            }
            return context.windowId
        }

        return createMainWindow(
            initialTerminalInput: suppressWelcome ? "" : nil,
            shouldActivate: shouldActivate
        )
    }

    func hasVisibleMainTerminalWindow() -> Bool {
        mainWindowContexts.values.contains { context in
            guard let window = resolvedWindow(for: context) else { return false }
            return window.isVisible && !window.isMiniaturized && window.alphaValue > 0.001
        }
    }

    @discardableResult
    func performNewWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        debugSource: String = "newWorkspace"
    ) -> Bool {
        let preferredContext = preferredTabManager.flatMap { mainWindowContext(for: $0) }
        let livePreferredContext: MainWindowContext? = {
            guard let preferredContext else { return nil }
            guard resolvedWindow(for: preferredContext) != nil else {
                discardOrphanedMainWindowContext(preferredContext)
                return nil
            }
            return preferredContext
        }()

        if mainWindowContexts.isEmpty && livePreferredContext == nil {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "fallback_new_window",
                source: debugSource,
                reason: "no_main_windows",
                event: event,
                chosenContext: nil
            )
#endif
            let windowId = createMainWindow()
            if let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
                let initialWorkspace = context.tabManager.selectedWorkspace
                _ = executeConfiguredNewWorkspaceActionIfAvailable(
                    in: context,
                    debugSource: debugSource,
                    replacingInitialWorkspace: initialWorkspace
                )
            }
            return true
        }

        let context = livePreferredContext
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)

        let workspaceGroupTarget = context.flatMap { workspaceGroupNewWorkspaceTarget(in: $0) }
        if let context,
           executeConfiguredNewWorkspaceActionIfAvailable(
               in: context,
               debugSource: debugSource,
               workspaceGroupTarget: workspaceGroupTarget
           ) {
            return true
        }

        if let context, let workspaceGroupTarget {
            return context.tabManager.createWorkspaceInGroup(
                groupId: workspaceGroupTarget.groupId,
                placement: workspaceGroupTarget.placement,
                referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId
            ) != nil
        }

        if let preferredTabManager,
           preferredContext == nil || livePreferredContext != nil {
            preferredTabManager.addWorkspace()
            return true
        }

        if addWorkspaceInPreferredMainWindow(event: event, debugSource: debugSource) == nil {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "fallback_new_window",
                source: debugSource,
                reason: "workspace_creation_returned_nil",
                event: event,
                chosenContext: nil
            )
#endif
            openNewMainWindow(nil)
        }
        return true
    }

    @discardableResult
    func performCloudVMAction(
        tabManager preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "cloudVM",
        onCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = nil
    ) -> Bool {
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        guard let context else {
            NSSound.beep()
            return false
        }
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: resolvedWindow(for: context) ?? preferredWindow,
            onCompletion: onCompletion
        )
    }

    func mainWindowContext(for tabManager: TabManager) -> MainWindowContext? {
        mainWindowContexts.values.first(where: { $0.tabManager === tabManager })
    }

    private func executeConfiguredNewWorkspaceActionIfAvailable(
        in context: MainWindowContext,
        debugSource: String,
        replacingInitialWorkspace initialWorkspace: Workspace? = nil,
        workspaceGroupTarget: WorkspaceGroupNewWorkspaceTarget? = nil
    ) -> Bool {
        guard let cmuxConfigStore = context.cmuxConfigStore,
              let action = cmuxConfigStore.resolvedNewWorkspaceAction() else {
            return false
        }
        guard let window = resolvedWindow(for: context) else {
            discardOrphanedMainWindowContext(context)
            return false
        }
#if DEBUG
        cmuxDebugLog(
            "newWorkspace.configCommand source=\(debugSource) " +
            "action=\(action.id) windowId=\(String(context.windowId.uuidString.prefix(8)))"
        )
#endif
        let initialWorkspaceId = initialWorkspace?.id
        if let workspaceGroupTarget,
           case .builtIn(.newWorkspace) = action.action {
            return context.tabManager.createWorkspaceInGroup(
                groupId: workspaceGroupTarget.groupId,
                placement: workspaceGroupTarget.placement,
                referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId
            ) != nil
        }

        let beforeIds = workspaceGroupTarget.map { _ in Set(context.tabManager.tabs.map(\.id)) }
        var asyncObserverId: UUID?
        let onExecuted: (() -> Void)? = (action.workspaceCommandName == nil && workspaceGroupTarget == nil) ? nil : { [weak self, weak context] in
            if let context,
               let workspaceGroupTarget,
               let beforeIds {
                let afterIds = context.tabManager.tabs.map(\.id)
                var newlyCreatedId: UUID?
                for id in afterIds where !beforeIds.contains(id) {
                    context.tabManager.addWorkspaceToGroup(
                        workspaceId: id,
                        groupId: workspaceGroupTarget.groupId,
                        placement: workspaceGroupTarget.placement,
                        referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId
                    )
                    newlyCreatedId = id
                    break
                }
                if newlyCreatedId == nil, case .builtIn(.cloudVM) = action.action {
                    asyncObserverId = ConfiguredGroupActionAsyncWorkspaceObserver.install(
                        tabManager: context.tabManager,
                        groupId: workspaceGroupTarget.groupId,
                        knownIds: Set(afterIds),
                        placement: workspaceGroupTarget.placement,
                        referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId
                    )
                }
            }
            if action.workspaceCommandName != nil {
                self?.closeInitialWorkspaceIfNeeded(
                    initialWorkspaceId: initialWorkspaceId,
                    in: context
                )
            }
        }
        let onCloudVMCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = workspaceGroupTarget == nil ? nil : { [weak context] completion in
            guard let context, let asyncObserverId else { return }
            ConfiguredGroupActionAsyncWorkspaceObserver.finishPending(
                tabManager: context.tabManager,
                observerId: asyncObserverId,
                workspaceId: completion.succeeded ? completion.workspaceId : nil
            )
        }
        return executeConfiguredCmuxAction(
            action,
            context: context,
            preferredWindow: window,
            onExecuted: onExecuted,
            onCloudVMCompletion: onCloudVMCompletion
        )
    }

    private func workspaceGroupNewWorkspaceTarget(in context: MainWindowContext) -> WorkspaceGroupNewWorkspaceTarget? {
        let tabManager = context.tabManager
        guard let selectedWorkspaceId = tabManager.selectedTabId,
              let selectedWorkspace = tabManager.tabs.first(where: { $0.id == selectedWorkspaceId }),
              let groupId = selectedWorkspace.groupId,
              let group = tabManager.workspaceGroups.first(where: { $0.id == groupId }) else {
            return nil
        }
        let anchorCwd = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId })?.currentDirectory
        let configured = context.cmuxConfigStore?.resolveWorkspaceGroupConfig(forCwd: anchorCwd)?.newWorkspacePlacement
        return WorkspaceGroupNewWorkspaceTarget(
            groupId: groupId,
            referenceWorkspaceId: selectedWorkspaceId,
            placement: configured ?? WorkspaceGroupNewWorkspacePlacementSettings.resolved()
        )
    }

    private func closeInitialWorkspaceIfNeeded(
        initialWorkspaceId: UUID?,
        in context: MainWindowContext?
    ) {
        guard let initialWorkspaceId,
              let context,
              context.tabManager.tabs.count > 1,
              let initialWorkspace = context.tabManager.tabs.first(where: { $0.id == initialWorkspaceId }),
              context.tabManager.selectedWorkspace?.id != initialWorkspaceId else {
            return
        }
        context.tabManager.closeWorkspace(initialWorkspace, recordHistory: false)
    }

    @discardableResult
    func showNewWorkspaceContextMenu(
        anchorView: NSView,
        event: NSEvent,
        debugSource: String = "titlebar.newWorkspace.contextMenu"
    ) -> Bool {
        let context = contextForMainWindow(anchorView.window)
            ?? mainWindowContext(forShortcutEvent: event, debugSource: debugSource)
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        guard let context,
              let cmuxConfigStore = context.cmuxConfigStore else {
            return false
        }

        let configuredItems = cmuxConfigStore.newWorkspaceContextMenuItems
        guard !configuredItems.isEmpty else { return false }

        let menu = NSMenu()
        for configuredItem in configuredItems {
            switch configuredItem {
            case .separator:
                if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
            case .action(let menuAction):
                let item = NSMenuItem(
                    title: menuAction.title,
                    action: #selector(performNewWorkspaceContextMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NewWorkspaceContextMenuActionBox(
                    windowId: context.windowId,
                    action: menuAction.action
                )
                item.toolTip = menuAction.tooltip
                item.image = menuAction.icon?.contextMenuImage(
                    configSourcePath: menuAction.iconSourcePath,
                    globalConfigPath: cmuxConfigStore.globalConfigPath
                )
                menu.addItem(item)
            }
        }

        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        guard menu.items.contains(where: { !$0.isSeparatorItem }) else { return false }

        NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
        return true
    }

    @objc private func performNewWorkspaceContextMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? NewWorkspaceContextMenuActionBox,
              let context = mainWindowContexts.values.first(where: { $0.windowId == box.windowId }),
              let window = resolvedWindow(for: context) else {
            NSSound.beep()
            return
        }
        guard executeConfiguredCmuxAction(box.action, context: context, preferredWindow: window) else {
            NSSound.beep()
            return
        }
    }

    /// Shows the "Open Folder" panel and creates a workspace for the selected directory.
    /// Called from both the SwiftUI menu and `handleCustomShortcut`.
    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "menu.file.openFolder.panelTitle", defaultValue: "Open Folder")
        panel.prompt = String(localized: "menu.file.openFolder.panelPrompt", defaultValue: "Open")
        // Seed the panel with the active workspace's directory. Use the shared
        // main-window resolver so this works even when an auxiliary window is key.
        if let context = preferredMainWindowContextForWorkspaceCreation(debugSource: "openFolderPanel.seed"),
           let cwd = context.tabManager.selectedWorkspace?.currentDirectory,
           !cwd.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: cwd)
        }
        if panel.runModal() == .OK, let url = panel.url {
            openWorkspaceForExternalDirectory(
                workingDirectory: url.path,
                debugSource: "shortcut.openFolder"
            )
        }
    }

    @discardableResult
    func openDirectoryInInlineVSCode(
        _ directoryURL: URL,
        tabManager preferredTabManager: TabManager? = nil
    ) -> Bool {
        guard let vscodeApplicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL() else {
            return false
        }

        let targetTabManager = preferredTabManager
            ?? preferredMainWindowContextForWorkspaceCreation(debugSource: "inlineVSCode.open.target")?.tabManager
        guard let targetTabManager else {
            return false
        }

        let targetWorkspaceId = targetTabManager.selectedWorkspace?.id
            ?? targetTabManager.tabs.first?.id
            ?? targetTabManager.addWorkspace(select: true).id
        let normalizedDirectoryURL = directoryURL.standardizedFileURL

        VSCodeServeWebController.shared.ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            guard let serveWebURL,
                  let openFolderURL = VSCodeServeWebURLBuilder.openFolderURL(
                      baseWebUIURL: serveWebURL,
                      directoryPath: normalizedDirectoryURL.path
                  ) else {
                NSSound.beep()
                return
            }

            guard targetTabManager.openBrowser(
                inWorkspace: targetWorkspaceId,
                url: openFolderURL,
                preferSplitRight: true
            ) != nil else {
                NSSound.beep()
                return
            }
        }

        return true
    }

    func showOpenFolderInInlineVSCodePanel(tabManager preferredTabManager: TabManager? = nil) {
        guard TerminalDirectoryOpenTarget.vscodeInline.isAvailable() else {
            NSSound.beep()
            return
        }

        let targetTabManager = preferredTabManager
            ?? preferredMainWindowContextForWorkspaceCreation(debugSource: "inlineVSCode.panel.target")?.tabManager
        guard let targetTabManager else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "menu.file.openFolderInVSCodeInline.panelTitle",
            defaultValue: "Open Folder in VS Code (Inline)"
        )
        panel.prompt = String(
            localized: "menu.file.openFolderInVSCodeInline.panelPrompt",
            defaultValue: "Open in VS Code"
        )
        if let cwd = targetTabManager.selectedWorkspace?.currentDirectory,
           !cwd.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: cwd)
        }

        if panel.runModal() == .OK,
           let url = panel.url,
           !openDirectoryInInlineVSCode(url, tabManager: targetTabManager) {
            NSSound.beep()
        }
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .window, error: error)
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .workspace, error: error)
    }

    func openWelcomeWorkspace() {
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: "welcome") else {
            return
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = context.tabManager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        sendWelcomeCommandWhenReady(to: workspace)
    }

    func sendWelcomeCommandWhenReady(to workspace: Workspace, markShownOnSend: Bool = false) {
        sendTextWhenReady("cmux welcome\n", to: workspace, beforeSend: {
            if markShownOnSend {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
            }
        })
    }

}
