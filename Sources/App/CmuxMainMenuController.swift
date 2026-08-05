import AppKit
import CMUXMobileCore
import CmuxFeedback
import CmuxIrohTransport
import CmuxPanes
import CmuxUpdater
import CmuxWorkspaces

@MainActor
private final class CmuxMainMenuInvocation: NSObject {
    let handler: () -> Void
    let isEnabled: () -> Bool

    init(
        isEnabled: @escaping () -> Bool = { true },
        handler: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.handler = handler
    }
}

/// Owns the process menu bar and exposes the same action graph to AppKit key
/// equivalents and the native command palette.
@MainActor
final class CmuxMainMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = CmuxMainMenuController()

    private enum Kind: String, CaseIterable {
        case application
        case file
        case edit
        case view
        case updatePill
        case notifications
        case history
        case window
        case help
        case debug

        var identifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("cmux.mainMenu.\(rawValue)")
        }
    }

    private weak var appDelegate: AppDelegate?
    private var installed = false

    private override init() {
        super.init()
    }

    func install(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate

        let mainMenu = NSMenu(title: "")
        addTopLevelMenu(
            to: mainMenu,
            title: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? ProcessInfo.processInfo.processName,
            kind: .application
        )
        addTopLevelMenu(
            to: mainMenu,
            title: String(localized: "menu.topLevel.file", defaultValue: "File"),
            kind: .file
        )
        addTopLevelMenu(
            to: mainMenu,
            title: String(localized: "menu.topLevel.edit", defaultValue: "Edit"),
            kind: .edit
        )
        addTopLevelMenu(
            to: mainMenu,
            title: String(localized: "menu.topLevel.view", defaultValue: "View"),
            kind: .view
        )
#if DEBUG
        addTopLevelMenu(
            to: mainMenu,
            title: String(localized: "debug.menu.updatePill", defaultValue: "Update Pill"),
            kind: .updatePill
        )
#endif
        addTopLevelMenu(
            to: mainMenu,
            title: String(localized: "menu.notifications.title", defaultValue: "Notifications"),
            kind: .notifications
        )
        addTopLevelMenu(
            to: mainMenu,
            title: String(localized: "menu.history.title", defaultValue: "History"),
            kind: .history
        )
#if DEBUG
        addTopLevelMenu(
            to: mainMenu,
            title: String(localized: "debug.menu.title", defaultValue: "Debug"),
            kind: .debug
        )
#endif
        let windowMenu = addTopLevelMenu(
            to: mainMenu,
            title: String(localized: "menu.topLevel.window", defaultValue: "Window"),
            kind: .window
        )
        let helpMenu = addTopLevelMenu(
            to: mainMenu,
            title: String(localized: "menu.topLevel.help", defaultValue: "Help"),
            kind: .help
        )

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
        installed = true
        rebuildAllMenus(in: mainMenu)
    }

    @discardableResult
    func refreshIfInstalled() -> Bool {
        guard installed, let mainMenu = NSApp.mainMenu else { return false }
        rebuildAllMenus(in: mainMenu)
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let kind = kind(for: menu) else { return }
        rebuild(menu, kind: kind)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let invocation = menuItem.representedObject as? CmuxMainMenuInvocation else {
            return true
        }
        return invocation.isEnabled()
    }

    @objc
    private func performMenuInvocation(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? CmuxMainMenuInvocation,
              invocation.isEnabled() else {
            NSSound.beep()
            return
        }
        invocation.handler()
    }

    @discardableResult
    private func addTopLevelMenu(
        to mainMenu: NSMenu,
        title: String,
        kind: Kind
    ) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.identifier = kind.identifier
        menu.delegate = self
        item.submenu = menu
        mainMenu.addItem(item)
        return menu
    }

    private func kind(for menu: NSMenu) -> Kind? {
        Kind.allCases.first { $0.identifier == menu.identifier }
    }

    private func rebuildAllMenus(in mainMenu: NSMenu) {
        for topLevelItem in mainMenu.items {
            guard let menu = topLevelItem.submenu, let kind = kind(for: menu) else { continue }
            rebuild(menu, kind: kind)
        }
    }

    private func rebuild(_ menu: NSMenu, kind: Kind) {
        menu.removeAllItems()
        switch kind {
        case .application:
            buildApplicationMenu(menu)
        case .file:
            buildFileMenu(menu)
        case .edit:
            buildEditMenu(menu)
        case .view:
            buildViewMenu(menu)
        case .updatePill:
            buildUpdatePillMenu(menu)
        case .notifications:
            buildNotificationsMenu(menu)
        case .history:
            buildHistoryMenu(menu)
        case .window:
            buildWindowMenu(menu)
        case .help:
            buildHelpMenu(menu)
        case .debug:
            buildDebugMenu(menu)
        }
    }

    @discardableResult
    private func addAction(
        _ title: String,
        to menu: NSMenu,
        shortcut action: KeyboardShortcutSettings.Action? = nil,
        state: NSControl.StateValue = .off,
        enabled: @escaping () -> Bool = { true },
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(performMenuInvocation(_:)),
            keyEquivalent: ""
        )
        let invocation = CmuxMainMenuInvocation(isEnabled: enabled, handler: handler)
        item.target = self
        item.representedObject = invocation
        item.state = state
        item.isEnabled = enabled()
        if let action {
            applyShortcut(KeyboardShortcutSettings.menuShortcut(for: action), to: item)
        }
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func addResponderAction(
        _ title: String,
        to menu: NSMenu,
        selector: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        menu.addItem(item)
        return item
    }

    private func addSeparator(to menu: NSMenu) {
        menu.addItem(.separator())
    }

    private func addSubmenu(_ title: String, to menu: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        menu.addItem(item)
        return submenu
    }

    private func applyShortcut(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard !shortcut.isUnbound,
              !shortcut.hasChord,
              let keyEquivalent = shortcut.menuItemKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    private var activeTabManager: TabManager? {
        appDelegate?.activeTabManagerForCommands(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    private func buildApplicationMenu(_ menu: NSMenu) {
        addAction(
            String(localized: "menu.app.about", defaultValue: "About cmux"),
            to: menu
        ) {
            AboutWindowController.shared.show()
        }
        addAction(
            String(localized: "menu.app.checkForUpdates", defaultValue: "Check for Updates…"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.checkForUpdates(nil)
        }
        if appDelegate?.updateViewModel.state.isInstallable == true {
            addAction(
                String(
                    localized: "update.installAndRelaunch",
                    defaultValue: "Install Update and Relaunch"
                ),
                to: menu
            ) { [weak self] in
                self?.appDelegate?.attemptUpdate()
            }
        }

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.app.settings", defaultValue: "Settings…"),
            to: menu,
            shortcut: .openSettings
        ) { [weak self] in
            self?.appDelegate?.openPreferencesWindow(debugSource: "nativeMenu.cmdComma")
        }
        addAction(
            String(localized: "menu.app.openCmuxSettingsFile", defaultValue: "Open cmux.json"),
            to: menu
        ) {
            openCmuxSettingsFileInEditor()
        }
        addAction(
            String(localized: "menu.app.ghosttySettings", defaultValue: "Ghostty Settings…"),
            to: menu
        ) {
            GhosttyApp.shared.openConfigurationInTextEdit()
        }
        addAction(
            String(
                localized: "menu.app.reloadConfiguration",
                defaultValue: "Reload Configuration"
            ),
            to: menu,
            shortcut: .reloadConfiguration
        ) { [weak self] in
            guard let self else { return }
            NSApp.sendAction(
                #selector(AppDelegate.reloadConfigurationMenuItem(_:)),
                to: self.appDelegate,
                from: nil
            )
        }
        addAction(
            String(
                localized: "menu.app.makeDefaultTerminal",
                defaultValue: "Make cmux the Default Terminal"
            ),
            to: menu
        ) {
            DefaultTerminalUserAction.setAsDefault(debugSource: "nativeMenu.makeDefaultTerminal")
        }

        addSeparator(to: menu)
        let servicesItem = NSMenuItem(
            title: String(localized: "menu.app.services", defaultValue: "Services"),
            action: nil,
            keyEquivalent: ""
        )
        let servicesMenu = NSMenu(title: servicesItem.title)
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.app.hide", defaultValue: "Hide cmux"),
            to: menu
        ) {
            NSApp.hide(nil)
        }.keyEquivalent = "h"
        let hideOthers = addAction(
            String(localized: "menu.app.hideOthers", defaultValue: "Hide Others"),
            to: menu
        ) {
            NSApp.hideOtherApplications(nil)
        }
        hideOthers.keyEquivalent = "h"
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        addAction(
            String(localized: "menu.app.showAll", defaultValue: "Show All"),
            to: menu
        ) {
            NSApp.unhideAllApplications(nil)
        }

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.quitCmux", defaultValue: "Quit cmux"),
            to: menu,
            shortcut: .quit
        ) {
            NSApp.terminate(nil)
        }
    }

    private func buildFileMenu(_ menu: NSMenu) {
        addAction(
            String(localized: "menu.file.newWindow", defaultValue: "New Window"),
            to: menu,
            shortcut: .newWindow
        ) { [weak self] in
            self?.appDelegate?.openNewMainWindow(nil)
        }
        addAction(
            String(localized: "menu.file.newWorkspace", defaultValue: "New Workspace"),
            to: menu,
            shortcut: .newTab
        ) { [weak self] in
            guard let self, let manager = self.activeTabManager else { return }
            self.appDelegate?.performNewWorkspaceAction(
                tabManager: manager,
                debugSource: "nativeMenu.newWorkspace"
            )
        }
        addAction(
            String(
                localized: "menu.file.newBrowserWorkspace",
                defaultValue: "New Browser Workspace"
            ),
            to: menu,
            shortcut: .newBrowserWorkspace,
            enabled: { BrowserAvailabilitySettings.isEnabled() }
        ) { [weak self] in
            guard let self, let manager = self.activeTabManager else { return }
            self.appDelegate?.performNewBrowserWorkspaceAction(
                tabManager: manager,
                debugSource: "nativeMenu.newBrowserWorkspace"
            )
        }
        if CmuxFeatureFlags.shared.isSimulatorEnabled {
            addAction(
                String(localized: "menu.file.newSimulatorPane", defaultValue: "New Simulator Pane"),
                to: menu
            ) { [weak self] in
                guard let self,
                      let manager = activeTabManager,
                      appDelegate?.executeConfiguredCmuxAction(
                        id: CmuxSurfaceTabBarBuiltInAction.newSimulator.configID,
                        tabManager: manager,
                        preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                      ) == true else {
                    NSSound.beep()
                    return
                }
            }
        }
        addAction(
            String(
                localized: "menu.file.newWorkspaceGroup",
                defaultValue: "New Workspace Group"
            ),
            to: menu,
            shortcut: .newWorkspaceGroup
        ) { [weak self] in
            guard let self, let manager = self.activeTabManager else { return }
            _ = self.appDelegate?.createEmptyWorkspaceGroup(
                tabManager: manager,
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
        addAction(
            String(localized: "menu.file.openFolder", defaultValue: "Open Folder…"),
            to: menu,
            shortcut: .openFolder
        ) { [weak self] in
            self?.appDelegate?.showOpenFolderPanel()
        }
        addAction(
            String(
                localized: "menu.file.openFolderInVSCodeInline",
                defaultValue: "Open Folder in VS Code (Inline)…"
            ),
            to: menu,
            enabled: { TerminalDirectoryOpenTarget.vscodeInline.isAvailable() }
        ) { [weak self] in
            self?.appDelegate?.showOpenFolderInInlineVSCodePanel()
        }

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.file.goToWorkspace", defaultValue: "Go to Workspace…"),
            to: menu,
            shortcut: .goToWorkspace
        ) {
            NotificationCenter.default.post(
                name: .commandPaletteSwitcherRequested,
                object: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
        addAction(
            String(localized: "menu.file.commandPalette", defaultValue: "Command Palette…"),
            to: menu,
            shortcut: .commandPalette
        ) {
            NotificationCenter.default.post(
                name: .commandPaletteRequested,
                object: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.file.closeTab", defaultValue: "Close Tab"),
            to: menu,
            shortcut: .closeTab,
            enabled: { [weak self] in self?.activeTabManager?.selectedWorkspace != nil }
        ) { [weak self] in
            self?.closePanelOrWindow()
        }
        addAction(
            String(
                localized: "menu.file.closeOtherTabs",
                defaultValue: "Close Other Tabs in Pane"
            ),
            to: menu,
            shortcut: .closeOtherTabsInPane,
            enabled: { [weak self] in
                self?.activeTabManager?.canCloseOtherTabsInFocusedPane() == true
            }
        ) { [weak self] in
            self?.activeTabManager?.closeOtherTabsInFocusedPaneWithConfirmation()
        }
        addAction(
            String(localized: "menu.file.closeWorkspace", defaultValue: "Close Workspace"),
            to: menu,
            shortcut: .closeWorkspace,
            enabled: { [weak self] in self?.activeTabManager?.selectedWorkspace != nil }
        ) { [weak self] in
            self?.activeTabManager?.closeCurrentTabWithConfirmation()
        }

        let workspaceMenu = addSubmenu(
            String(localized: "commandPalette.switcher.workspaceLabel", defaultValue: "Workspace"),
            to: menu
        )
        buildWorkspaceMenu(workspaceMenu)

        addSeparator(to: menu)
        addResponderAction(
            String(localized: "menu.file.close", defaultValue: "Close"),
            to: menu,
            selector: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w",
            modifiers: [.command]
        )
        addResponderAction(
            String(localized: "menu.file.closeAll", defaultValue: "Close All"),
            to: menu,
            selector: Selector(("closeAll:")),
            keyEquivalent: "w",
            modifiers: [.command, .option]
        )
    }

    private func buildEditMenu(_ menu: NSMenu) {
        addResponderAction(
            String(localized: "menu.edit.undo", defaultValue: "Undo"),
            to: menu,
            selector: Selector(("undo:")),
            keyEquivalent: "z",
            modifiers: [.command]
        )
        addResponderAction(
            String(localized: "menu.edit.redo", defaultValue: "Redo"),
            to: menu,
            selector: Selector(("redo:")),
            keyEquivalent: "Z",
            modifiers: [.command, .shift]
        )
        addSeparator(to: menu)
        addResponderAction(
            String(localized: "menu.edit.cut", defaultValue: "Cut"),
            to: menu,
            selector: #selector(NSText.cut(_:)),
            keyEquivalent: "x",
            modifiers: [.command]
        )
        addResponderAction(
            String(localized: "menu.edit.copy", defaultValue: "Copy"),
            to: menu,
            selector: #selector(NSText.copy(_:)),
            keyEquivalent: "c",
            modifiers: [.command]
        )
        addResponderAction(
            String(localized: "menu.edit.paste", defaultValue: "Paste"),
            to: menu,
            selector: #selector(NSText.paste(_:)),
            keyEquivalent: "v",
            modifiers: [.command]
        )
        addResponderAction(
            String(localized: "menu.edit.delete", defaultValue: "Delete"),
            to: menu,
            selector: #selector(NSText.delete(_:))
        )
        addResponderAction(
            String(localized: "menu.edit.selectAll", defaultValue: "Select All"),
            to: menu,
            selector: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a",
            modifiers: [.command]
        )

        addSeparator(to: menu)
        let findMenu = addSubmenu(
            String(localized: "menu.find.title", defaultValue: "Find"),
            to: menu
        )
        buildFindMenu(findMenu)
    }

    private func buildFindMenu(_ menu: NSMenu) {
        addAction(
            String(localized: "menu.find.find", defaultValue: "Find…"),
            to: menu,
            shortcut: .find
        ) { [weak self] in
            _ = self?.appDelegate?.performFindShortcutInActiveMainWindow(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
        addAction(
            String(localized: "menu.find.findInDirectory", defaultValue: "Find in Directory…"),
            to: menu,
            shortcut: .findInDirectory
        ) { [weak self] in
            _ = self?.appDelegate?.focusFileSearchInActiveMainWindow(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
        addAction(
            String(localized: "menu.find.findNext", defaultValue: "Find Next"),
            to: menu,
            shortcut: .findNext
        ) { [weak self] in
            self?.restoreFindTargetFocus()
            self?.activeTabManager?.findNext()
        }
        addAction(
            String(localized: "menu.find.findPrevious", defaultValue: "Find Previous"),
            to: menu,
            shortcut: .findPrevious
        ) { [weak self] in
            self?.restoreFindTargetFocus()
            self?.activeTabManager?.findPrevious()
        }
        addSeparator(to: menu)
        addAction(
            String(localized: "menu.find.hideFindBar", defaultValue: "Hide Find Bar"),
            to: menu,
            shortcut: .hideFind,
            enabled: { [weak self] in self?.activeTabManager?.isFindVisible == true }
        ) { [weak self] in
            self?.restoreFindTargetFocus()
            self?.activeTabManager?.hideFind()
        }
        addSeparator(to: menu)
        addAction(
            String(
                localized: "menu.find.useSelectionForFind",
                defaultValue: "Use Selection for Find"
            ),
            to: menu,
            shortcut: .useSelectionForFind,
            enabled: { [weak self] in self?.activeTabManager?.canUseSelectionForFind == true }
        ) { [weak self] in
            self?.restoreFindTargetFocus()
            self?.activeTabManager?.searchSelection()
        }
        addSeparator(to: menu)
        addAction(
            String(
                localized: "menu.find.sendCtrlFToTerminal",
                defaultValue: "Send Ctrl-F to Terminal"
            ),
            to: menu,
            shortcut: .sendCtrlFToTerminal,
            enabled: { [weak self] in self?.activeTabManager?.selectedTerminalPanel != nil }
        ) { [weak self] in
            self?.restoreFindTargetFocus()
            if self?.activeTabManager?.sendCtrlFToFocusedTerminal() != true {
                NSSound.beep()
            }
        }
    }

    private func restoreFindTargetFocus() {
        _ = appDelegate?.restoreFocusedMainPanelFocusFromRightSidebar(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    private func closePanelOrWindow() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let window, cmuxWindowShouldOwnCloseShortcut(window) {
            window.performClose(nil)
            return
        }
        if appDelegate?.closeFocusedDockPanelForCommand(preferredWindow: window) == true {
            return
        }
        activeTabManager?.closeCurrentPanelWithConfirmation()
    }

    private func buildViewMenu(_ menu: NSMenu) {
        addAction(
            String(localized: "menu.view.toggleLeftSidebar", defaultValue: "Toggle Left Sidebar"),
            to: menu,
            shortcut: .toggleSidebar
        ) { [weak self] in
            if SettingsWindowPresenter.handleSidebarToggleIfSettingsWindowIsKey(
                keyWindow: NSApp.keyWindow
            ) {
                return
            }
            if self?.appDelegate?.toggleSidebarInActiveMainWindow() != true {
                NSSound.beep()
            }
        }
        addAction(
            String(localized: "menu.view.toggleRightSidebar", defaultValue: "Toggle Right Sidebar"),
            to: menu,
            shortcut: .toggleRightSidebar
        ) { [weak self] in
            if self?.appDelegate?.toggleRightSidebarInActiveMainWindow(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) != true {
                NSSound.beep()
            }
        }
        addAction(
            String(
                localized: "menu.view.focusRightSidebar",
                defaultValue: "Toggle Right Sidebar Focus"
            ),
            to: menu,
            shortcut: .focusRightSidebar
        ) { [weak self] in
            guard let self else { return }
            if self.appDelegate?.toggleRightSidebarKeyboardFocusInActiveMainWindow() == true {
                return
            }
            if self.appDelegate?.focusRightSidebarInActiveMainWindow(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) != true {
                NSSound.beep()
            }
        }

        addSeparator(to: menu)
        buildSurfaceNavigationItems(menu)

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.view.back", defaultValue: "Back"),
            to: menu,
            shortcut: .browserBack,
            enabled: { [weak self] in self?.activeTabManager?.focusedBrowserPanel != nil }
        ) { [weak self] in
            self?.activeTabManager?.focusedBrowserPanel?.goBack()
        }
        addAction(
            String(localized: "menu.view.forward", defaultValue: "Forward"),
            to: menu,
            shortcut: .browserForward,
            enabled: { [weak self] in self?.activeTabManager?.focusedBrowserPanel != nil }
        ) { [weak self] in
            self?.activeTabManager?.focusedBrowserPanel?.goForward()
        }
        addAction(
            String(localized: "menu.view.reloadPage", defaultValue: "Reload Page"),
            to: menu,
            shortcut: .browserReload,
            enabled: { [weak self] in self?.activeTabManager?.focusedBrowserPanel != nil }
        ) { [weak self] in
            self?.activeTabManager?.focusedBrowserPanel?.reload()
        }
        addAction(
            String(localized: "menu.view.toggleDevTools", defaultValue: "Toggle Developer Tools"),
            to: menu,
            shortcut: .toggleBrowserDeveloperTools,
            enabled: { [weak self] in self?.activeTabManager?.focusedBrowserPanel != nil }
        ) { [weak self] in
            if self?.activeTabManager?.toggleDeveloperToolsFocusedBrowser() != true {
                NSSound.beep()
            }
        }
        addAction(
            String(localized: "menu.view.showJSConsole", defaultValue: "Show JavaScript Console"),
            to: menu,
            shortcut: .showBrowserJavaScriptConsole,
            enabled: { [weak self] in self?.activeTabManager?.focusedBrowserPanel != nil }
        ) { [weak self] in
            if self?.activeTabManager?.showJavaScriptConsoleFocusedBrowser() != true {
                NSSound.beep()
            }
        }
        addAction(
            String(localized: "menu.view.toggleReactGrab", defaultValue: "Toggle React Grab"),
            to: menu,
            shortcut: .toggleReactGrab
        ) { [weak self] in
            if self?.activeTabManager?.toggleReactGrabFromCurrentFocus() != true {
                NSSound.beep()
            }
        }
        addAction(
            String(localized: "menu.view.toggleDesignMode", defaultValue: "Toggle Design Mode"),
            to: menu,
            shortcut: .toggleBrowserDesignMode,
            enabled: { [weak self] in self?.activeTabManager?.focusedBrowserPanel != nil }
        ) { [weak self] in
            guard let panel = self?.activeTabManager?.focusedBrowserPanel else {
                NSSound.beep()
                return
            }
            Task { @MainActor in
                _ = await panel.toggleDesignMode(reason: "nativeViewMenu")
            }
        }

        let focusModeActive = activeTabManager?.focusedBrowserPanel?.isBrowserFocusModeActive == true
        addAction(
            focusModeActive
                ? String(
                    localized: "menu.view.exitBrowserFocusMode",
                    defaultValue: "Exit Browser Focus Mode"
                )
                : String(
                    localized: "menu.view.enterBrowserFocusMode",
                    defaultValue: "Enter Browser Focus Mode"
                ),
            to: menu,
            enabled: { [weak self] in
                self?.activeTabManager?.focusedBrowserPanel?.canToggleBrowserFocusMode == true
            }
        ) { [weak self] in
            if self?.activeTabManager?.toggleBrowserFocusModeForFocusedBrowser(
                reason: "nativeViewMenu"
            ) != true {
                NSSound.beep()
            }
        }
        addAction(
            String(localized: "menu.view.zoomIn", defaultValue: "Zoom In"),
            to: menu,
            shortcut: .browserZoomIn
        ) { [weak self] in
            _ = self?.activeTabManager?.zoomInFocusedBrowserOrTextFilePreview()
        }
        addAction(
            String(localized: "menu.view.zoomOut", defaultValue: "Zoom Out"),
            to: menu,
            shortcut: .browserZoomOut
        ) { [weak self] in
            _ = self?.activeTabManager?.zoomOutFocusedBrowserOrTextFilePreview()
        }
        addAction(
            String(localized: "menu.view.actualSize", defaultValue: "Actual Size"),
            to: menu,
            shortcut: .browserZoomReset
        ) { [weak self] in
            _ = self?.activeTabManager?.resetZoomFocusedBrowserOrTextFilePreview()
        }
        addAction(
            String(localized: "menu.view.clearBrowserHistory", defaultValue: "Clear Browser History"),
            to: menu
        ) {
            BrowserHistoryStore.shared.clearHistory()
        }
        addAction(
            String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"),
            to: menu
        ) {
            Task { @MainActor in
                await Task.yield()
                BrowserDataImportCoordinator.shared.presentImportDialog()
            }
        }

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.view.nextWorkspace", defaultValue: "Next Workspace"),
            to: menu,
            shortcut: .nextSidebarTab
        ) { [weak self] in
            self?.activeTabManager?.selectNextTab()
        }
        addAction(
            String(localized: "menu.view.previousWorkspace", defaultValue: "Previous Workspace"),
            to: menu,
            shortcut: .prevSidebarTab
        ) { [weak self] in
            self?.activeTabManager?.selectPreviousTab()
        }
        addAction(
            String(localized: "shortcut.moveWorkspaceUp.label", defaultValue: "Move Workspace Up"),
            to: menu,
            shortcut: .moveWorkspaceUp
        ) { [weak self] in
            self?.activeTabManager?.moveSelectedWorkspace(by: -1)
        }
        addAction(
            String(
                localized: "shortcut.moveWorkspaceDown.label",
                defaultValue: "Move Workspace Down"
            ),
            to: menu,
            shortcut: .moveWorkspaceDown
        ) { [weak self] in
            self?.activeTabManager?.moveSelectedWorkspace(by: 1)
        }
        addAction(
            String(localized: "menu.view.renameWorkspace", defaultValue: "Rename Workspace…"),
            to: menu,
            shortcut: .renameWorkspace,
            enabled: { [weak self] in self?.activeTabManager?.selectedWorkspace != nil }
        ) { [weak self] in
            _ = self?.appDelegate?.requestRenameWorkspaceViaCommandPalette()
        }
        addAction(
            String(
                localized: "menu.view.editWorkspaceDescription",
                defaultValue: "Edit Workspace Description…"
            ),
            to: menu,
            shortcut: .editWorkspaceDescription,
            enabled: { [weak self] in self?.activeTabManager?.selectedWorkspace != nil }
        ) { [weak self] in
            _ = self?.appDelegate?.requestEditWorkspaceDescriptionViaCommandPalette()
        }

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.view.splitRight", defaultValue: "Split Right"),
            to: menu,
            shortcut: .splitRight
        ) { [weak self] in
            self?.performSplit(direction: .right, browser: false)
        }
        addAction(
            String(localized: "menu.view.splitDown", defaultValue: "Split Down"),
            to: menu,
            shortcut: .splitDown
        ) { [weak self] in
            self?.performSplit(direction: .down, browser: false)
        }
        addAction(
            String(localized: "menu.view.splitBrowserRight", defaultValue: "Split Browser Right"),
            to: menu,
            shortcut: .splitBrowserRight
        ) { [weak self] in
            self?.performSplit(direction: .right, browser: true)
        }
        addAction(
            String(localized: "menu.view.splitBrowserDown", defaultValue: "Split Browser Down"),
            to: menu,
            shortcut: .splitBrowserDown
        ) { [weak self] in
            self?.performSplit(direction: .down, browser: true)
        }
        addAction(
            String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits"),
            to: menu,
            shortcut: .equalizeSplits,
            enabled: { [weak self] in self?.activeTabManager?.selectedWorkspace != nil }
        ) { [weak self] in
            guard let manager = self?.activeTabManager,
                  let workspace = manager.selectedWorkspace else { return }
            _ = manager.equalizeSplits(tabId: workspace.id)
        }

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.view.toggleCanvasLayout", defaultValue: "Toggle Canvas Layout"),
            to: menu,
            shortcut: .toggleCanvasLayout,
            enabled: { [weak self] in self?.activeTabManager?.selectedWorkspace != nil }
        ) { [weak self] in
            guard let workspace = self?.activeTabManager?.selectedWorkspace else { return }
            CanvasActionExecutor(workspace: workspace).perform(.toggleLayout)
        }
        addAction(
            String(localized: "menu.view.canvasOverview", defaultValue: "Canvas Overview"),
            to: menu,
            shortcut: .canvasOverview,
            enabled: { [weak self] in self?.activeTabManager?.selectedWorkspace != nil }
        ) { [weak self] in
            guard let workspace = self?.activeTabManager?.selectedWorkspace else { return }
            CanvasActionExecutor(workspace: workspace).perform(.toggleOverview)
        }
        addAction(
            String(localized: "menu.view.canvasTidy", defaultValue: "Tidy Canvas"),
            to: menu,
            shortcut: .canvasTidy,
            enabled: { [weak self] in self?.activeTabManager?.selectedWorkspace != nil }
        ) { [weak self] in
            guard let workspace = self?.activeTabManager?.selectedWorkspace else { return }
            CanvasActionExecutor(workspace: workspace).perform(.alignment(.tidy))
        }

        addSeparator(to: menu)
        addNumberedWorkspaceItems(menu)

        addSeparator(to: menu)
        addAction(
            String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen"),
            to: menu,
            shortcut: .toggleFullScreen,
            enabled: { NSApp.keyWindow != nil || NSApp.mainWindow != nil }
        ) {
            (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
        }
        addAction(
            String(localized: "menu.view.jumpToUnread", defaultValue: "Jump to Latest Unread"),
            to: menu,
            shortcut: .jumpToUnread
        ) { [weak self] in
            self?.appDelegate?.jumpToLatestUnread()
        }
        addAction(
            String(localized: "menu.view.showNotifications", defaultValue: "Show Notifications"),
            to: menu,
            shortcut: .showNotifications
        ) { [weak self] in
            self?.appDelegate?.toggleNotificationsPopover(animated: false)
        }
    }

    private func buildSurfaceNavigationItems(_ menu: NSMenu) {
        addAction(
            String(localized: "menu.view.nextSurface", defaultValue: "Next Surface"),
            to: menu,
            shortcut: .nextSurface
        ) { [weak self] in
            self?.activeTabManager?.selectNextSurface()
        }
        addAction(
            String(localized: "menu.view.previousSurface", defaultValue: "Previous Surface"),
            to: menu,
            shortcut: .prevSurface
        ) { [weak self] in
            self?.activeTabManager?.selectPreviousSurface()
        }
        addAction(
            String(
                localized: "shortcut.moveSurfaceLeft.label",
                defaultValue: "Reorder Surface Left"
            ),
            to: menu,
            shortcut: .moveSurfaceLeft
        ) { [weak self] in
            self?.activeTabManager?.selectedWorkspace?.moveSelectedSurface(by: -1)
        }
        addAction(
            String(
                localized: "shortcut.moveSurfaceRight.label",
                defaultValue: "Reorder Surface Right"
            ),
            to: menu,
            shortcut: .moveSurfaceRight
        ) { [weak self] in
            self?.activeTabManager?.selectedWorkspace?.moveSelectedSurface(by: 1)
        }
        for movement in SurfacePaneMovement.allCases {
            addAction(
                movement.title,
                to: menu,
                shortcut: movement.shortcutAction
            ) { [weak self] in
                guard let self, let manager = self.activeTabManager else { return }
                if self.appDelegate?.performSurfacePaneMovement(
                    movement,
                    tabManager: manager,
                    preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                ) != true {
                    NSSound.beep()
                }
            }
        }
    }

    private func performSplit(direction: SplitDirection, browser: Bool) {
        guard let manager = activeTabManager else { return }
        if browser {
            if appDelegate?.performBrowserSplitShortcut(direction: direction) != true {
                _ = manager.createBrowserSplit(direction: direction)
            }
        } else if appDelegate?.performSplitShortcut(direction: direction) != true {
            manager.createSplit(direction: direction)
        }
    }

    private func addNumberedWorkspaceItems(_ menu: NSMenu) {
        let shortcut = KeyboardShortcutSettings.menuShortcut(for: .selectWorkspaceByNumber)
        for number in 1...9 {
            let item = addAction(
                String(localized: "menu.view.workspace", defaultValue: "Workspace \(number)"),
                to: menu,
                enabled: { [weak self] in
                    guard let count = self?.activeTabManager?.tabs.count else { return false }
                    return count > 0 && (number <= count || number == 9)
                }
            ) { [weak self] in
                self?.activeTabManager?.selectWorkspaceByNumber(number)
            }
            if !shortcut.isUnbound, !shortcut.hasChord {
                item.keyEquivalent = String(number)
                item.keyEquivalentModifierMask = shortcut.modifierFlags
            }
        }
    }

    private func buildNotificationsMenu(_ menu: NSMenu) {
        let snapshot = TerminalNotificationStore.shared.notificationMenuSnapshot
        let hint = NSMenuItem(title: snapshot.stateHintTitle, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        if !snapshot.recentNotifications.isEmpty {
            addSeparator(to: menu)
            for notification in snapshot.recentNotifications {
                let tabTitle = appDelegate?.tabTitle(for: notification.tabId) ?? ""
                addAction(
                    MenuBarNotificationLineFormatter.menuTitle(
                        notification: notification,
                        tabTitle: tabTitle
                    ),
                    to: menu
                ) { [weak self] in
                    _ = self?.appDelegate?.openTerminalNotification(notification)
                }
            }
            addSeparator(to: menu)
        }

        addAction(
            String(localized: "menu.notifications.show", defaultValue: "Show Notifications"),
            to: menu,
            shortcut: .showNotifications
        ) { [weak self] in
            self?.appDelegate?.toggleNotificationsPopover(animated: false)
        }
        addAction(
            String(
                localized: "menu.notifications.jumpToUnread",
                defaultValue: "Jump to Latest Unread"
            ),
            to: menu,
            shortcut: .jumpToUnread,
            enabled: { snapshot.hasUnreadNotifications }
        ) { [weak self] in
            self?.appDelegate?.jumpToLatestUnread()
        }
        addAction(
            String(localized: "menu.notifications.toggleUnread", defaultValue: "Toggle Unread"),
            to: menu,
            shortcut: .toggleUnread,
            enabled: { [weak self] in self?.activeTabManager?.selectedWorkspace != nil }
        ) { [weak self] in
            self?.appDelegate?.toggleFocusedNotificationUnread()
        }
        addAction(
            String(localized: "menu.notifications.markAllRead", defaultValue: "Mark All Read"),
            to: menu,
            enabled: { snapshot.hasUnreadNotifications }
        ) {
            TerminalNotificationStore.shared.markAllRead()
        }
        addAction(
            String(localized: "menu.notifications.clearAll", defaultValue: "Clear All"),
            to: menu,
            enabled: { snapshot.hasNotifications }
        ) {
            TerminalNotificationStore.shared.clearAll()
        }
    }

    private func buildHistoryMenu(_ menu: NSMenu) {
        guard let manager = activeTabManager else { return }
        let back = manager.focusHistoryMenuSnapshot(direction: .back)
        let forward = manager.focusHistoryMenuSnapshot(direction: .forward)
        let focusedSnapshot = FocusHistoryMenuSnapshot.recentlyFocused(
            back: back,
            forward: forward,
            maxItemCount: 10
        )
        let closedSnapshot = ClosedItemHistoryStore.shared.menuSnapshot(maxItemCount: 10)

        addAction(
            String(localized: "menu.history.focusBack", defaultValue: "Focus Back"),
            to: menu,
            shortcut: .focusHistoryBack,
            enabled: { [weak manager] in manager?.canNavigateBack == true }
        ) { [weak manager] in
            manager?.navigateBack()
        }
        addAction(
            String(localized: "menu.history.focusForward", defaultValue: "Focus Forward"),
            to: menu,
            shortcut: .focusHistoryForward,
            enabled: { [weak manager] in manager?.canNavigateForward == true }
        ) { [weak manager] in
            manager?.navigateForward()
        }

        addSeparator(to: menu)
        let focusedHeader = NSMenuItem(
            title: HistoryMenuLineFormatter.titleWithSubtitle(
                title: String(localized: "menu.history.recentlyFocused", defaultValue: "Recently Focused"),
                subtitle: String(
                    localized: "menu.history.recentlyFocused.subtitle",
                    defaultValue: "Most recent focus targets"
                )
            ),
            action: nil,
            keyEquivalent: ""
        )
        focusedHeader.isEnabled = false
        menu.addItem(focusedHeader)
        if focusedSnapshot.items.isEmpty {
            let empty = NSMenuItem(
                title: String(localized: "menu.history.noFocusHistory", defaultValue: "No Focus History"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for item in focusedSnapshot.items {
                addAction(
                    FocusHistoryMenuFormatter.menuTitle(for: item),
                    to: menu,
                    enabled: { item.isNavigable }
                ) { [weak manager] in
                    if manager?.navigateToFocusHistoryMenuItem(item) != true {
                        NSSound.beep()
                    }
                }
            }
        }

        addSeparator(to: menu)
        addAction(
            String(
                localized: "menu.history.reopenClosedWorkspace",
                defaultValue: "Reopen Closed Workspace"
            ),
            to: menu,
            shortcut: .reopenClosedWorkspace
        ) { [weak self, weak manager] in
            guard let manager else { return }
            if self?.appDelegate?.reopenMostRecentlyClosedWorkspace(
                preferredTabManager: manager
            ) != true {
                NSSound.beep()
            }
        }
        addAction(
            String(localized: "menu.history.reopenLastClosed", defaultValue: "Reopen Last Closed"),
            to: menu,
            shortcut: .reopenClosedBrowserPanel
        ) { [weak self, weak manager] in
            guard let manager else { return }
            if self?.appDelegate?.reopenMostRecentlyClosedItem(
                preferredTabManager: manager
            ) != true {
                NSSound.beep()
            }
        }

        let closedHeader = NSMenuItem(
            title: HistoryMenuLineFormatter.titleWithSubtitle(
                title: String(localized: "menu.history.recentlyClosed", defaultValue: "Recently Closed"),
                subtitle: String(
                    localized: "menu.history.recentlyClosed.subtitle",
                    defaultValue: "Tabs, workspaces, and windows"
                )
            ),
            action: nil,
            keyEquivalent: ""
        )
        closedHeader.isEnabled = false
        menu.addItem(closedHeader)
        if closedSnapshot.items.isEmpty {
            let empty = NSMenuItem(
                title: String(
                    localized: "menu.history.recentlyClosed.empty",
                    defaultValue: "No Recently Closed Items"
                ),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for item in closedSnapshot.items {
                addAction(item.menuTitle, to: menu) { [weak self, weak manager] in
                    guard let manager else { return }
                    if self?.appDelegate?.reopenClosedHistoryItem(
                        id: item.id,
                        preferredTabManager: manager
                    ) != true {
                        NSSound.beep()
                    }
                }
            }
        }

        addSeparator(to: menu)
        addAction(
            String(
                localized: "menu.file.restorePreviousAppLaunch",
                defaultValue: "Restore Previous Launch"
            ),
            to: menu,
            shortcut: .reopenPreviousSession
        ) { [weak self] in
            if self?.appDelegate?.reopenPreviousSession() != true {
                NSSound.beep()
            }
        }
    }

    private func buildWorkspaceMenu(_ menu: NSMenu) {
        guard let manager = activeTabManager else { return }
        let workspace = manager.selectedWorkspace
        let workspaceIndex = workspace.flatMap { selectedWorkspace in
            manager.tabs.firstIndex(where: { $0.id == selectedWorkspace.id })
        }
        let referenceWindowId = appDelegate?.windowId(for: manager)
        let moveTargets = appDelegate?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        let pinState = WorkspacePinCommands.selectedWorkspacePinState(in: manager)

        addAction(
            WorkspacePinCommands.selectedWorkspaceMenuLabel(in: manager, pinState: pinState),
            to: menu,
            enabled: { pinState != nil }
        ) {
            if !WorkspacePinCommands.toggleSelectedWorkspace(in: manager) {
                NSSound.beep()
            }
        }
        addAction(
            String(localized: "menu.view.renameWorkspace", defaultValue: "Rename Workspace…"),
            to: menu,
            enabled: { workspace != nil }
        ) { [weak self] in
            _ = self?.appDelegate?.requestRenameWorkspaceViaCommandPalette()
        }
        addAction(
            String(
                localized: "menu.view.editWorkspaceDescription",
                defaultValue: "Edit Workspace Description…"
            ),
            to: menu,
            enabled: { workspace != nil }
        ) { [weak self] in
            _ = self?.appDelegate?.requestEditWorkspaceDescriptionViaCommandPalette()
        }
        if workspace?.hasCustomTitle == true {
            addAction(
                String(
                    localized: "contextMenu.removeCustomWorkspaceName",
                    defaultValue: "Remove Custom Workspace Name"
                ),
                to: menu
            ) {
                guard let workspace else { return }
                manager.clearCustomTitle(tabId: workspace.id)
            }
        }

        addSeparator(to: menu)
        addAction(
            String(localized: "contextMenu.moveUp", defaultValue: "Move Up"),
            to: menu,
            enabled: { workspaceIndex != nil && workspaceIndex != 0 }
        ) {
            manager.moveSelectedWorkspace(by: -1)
        }
        addAction(
            String(localized: "contextMenu.moveDown", defaultValue: "Move Down"),
            to: menu,
            enabled: { workspaceIndex != nil && workspaceIndex != manager.tabs.count - 1 }
        ) {
            manager.moveSelectedWorkspace(by: 1)
        }
        addAction(
            String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"),
            to: menu,
            enabled: { workspace != nil && workspaceIndex != 0 }
        ) {
            guard let workspace else { return }
            manager.moveTabsToTop([workspace.id])
            manager.selectWorkspace(workspace)
        }

        let moveMenu = addSubmenu(
            String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window"),
            to: menu
        )
        addAction(
            String(localized: "contextMenu.newWindow", defaultValue: "New Window"),
            to: moveMenu,
            enabled: { workspace != nil }
        ) { [weak self] in
            guard let workspace else { return }
            _ = self?.appDelegate?.moveWorkspaceToNewWindow(workspaceId: workspace.id, focus: true)
        }
        if !moveTargets.isEmpty {
            addSeparator(to: moveMenu)
        }
        for target in moveTargets {
            addAction(
                target.label,
                to: moveMenu,
                enabled: { !target.isCurrentWindow && workspace != nil }
            ) { [weak self] in
                guard let workspace else { return }
                _ = self?.appDelegate?.moveWorkspaceToWindow(
                    workspaceId: workspace.id,
                    windowId: target.windowId,
                    focus: true
                )
            }
        }

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.file.closeWorkspace", defaultValue: "Close Workspace"),
            to: menu,
            enabled: { workspace != nil }
        ) {
            manager.closeCurrentWorkspaceWithConfirmation()
        }
        addAction(
            String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces"),
            to: menu,
            enabled: { workspace != nil && manager.tabs.count > 1 }
        ) {
            guard let workspace else { return }
            manager.closeWorkspacesWithConfirmation(
                manager.tabs.compactMap { $0.id == workspace.id ? nil : $0.id },
                allowPinned: true
            )
        }
        addAction(
            String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below"),
            to: menu,
            enabled: { workspaceIndex != nil && workspaceIndex != manager.tabs.count - 1 }
        ) {
            guard let workspaceIndex else { return }
            manager.closeWorkspacesWithConfirmation(
                manager.tabs.suffix(from: workspaceIndex + 1).map(\.id),
                allowPinned: true
            )
        }
        addAction(
            String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above"),
            to: menu,
            enabled: { workspaceIndex != nil && workspaceIndex != 0 }
        ) {
            guard let workspaceIndex else { return }
            manager.closeWorkspacesWithConfirmation(
                manager.tabs.prefix(upTo: workspaceIndex).map(\.id),
                allowPinned: true
            )
        }

        addSeparator(to: menu)
        let workspaceID = workspace?.id
        addAction(
            String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            to: menu,
            enabled: {
                guard let workspaceID else { return false }
                return TerminalNotificationStore.shared.canMarkWorkspaceRead(forTabIds: [workspaceID])
            }
        ) {
            guard let workspaceID else { return }
            TerminalNotificationStore.shared.markRead(forTabId: workspaceID)
        }
        addAction(
            String(
                localized: "contextMenu.markWorkspaceUnread",
                defaultValue: "Mark Workspace as Unread"
            ),
            to: menu,
            enabled: {
                guard let workspaceID else { return false }
                return TerminalNotificationStore.shared.canMarkWorkspaceUnread(forTabIds: [workspaceID])
            }
        ) {
            guard let workspaceID else { return }
            TerminalNotificationStore.shared.markUnread(forTabId: workspaceID)
        }
    }

    private func buildWindowMenu(_ menu: NSMenu) {
        addResponderAction(
            String(localized: "menu.window.minimize", defaultValue: "Minimize"),
            to: menu,
            selector: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m",
            modifiers: [.command]
        )
        addResponderAction(
            String(localized: "menu.window.zoom", defaultValue: "Zoom"),
            to: menu,
            selector: #selector(NSWindow.performZoom(_:))
        )
        addSeparator(to: menu)
        addAction(
            String(localized: "menu.window.taskManager", defaultValue: "Task Manager..."),
            to: menu
        ) {
            TaskManagerWindowController.shared.show()
        }
        addSeparator(to: menu)
        addAction(
            String(localized: "menu.window.bringAllToFront", defaultValue: "Bring All to Front"),
            to: menu
        ) {
            NSApp.arrangeInFront(nil)
        }
    }

    private func buildHelpMenu(_ menu: NSMenu) {
        let primary: [CmuxHelpResource] = [
            .gettingStarted,
            .concepts,
            .configuration,
            .customCommands,
            .dock,
            .keyboardShortcuts,
            .apiReference,
            .browserAutomation,
            .notifications,
            .ssh,
            .skills,
        ]
        for resource in primary {
            addHelpResource(resource, to: menu)
        }

        let integrations = addSubmenu(
            String(localized: "menu.help.agentIntegrations", defaultValue: "Agent Integrations"),
            to: menu
        )
        for resource in [
            CmuxHelpResource.claudeCodeTeams,
            .ohMyOpenCode,
            .ohMyCodex,
            .ohMyClaudeCode,
        ] {
            addHelpResource(resource, to: integrations)
        }
        addHelpResource(.changelog, to: menu)

        addSeparator(to: menu)
        addAction(
            String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback"),
            to: menu,
            shortcut: .sendFeedback
        ) { [weak self] in
            self?.presentFeedback()
        }
        addAction(
            String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.checkForUpdates(nil)
        }

        addSeparator(to: menu)
        addHelpResource(.githubIssues, to: menu)
        addHelpResource(.discord, to: menu)
        if CmuxFeatureFlags.shared.isProUpgradeUIEnabled {
            addAction(
                String(localized: "menu.help.upgradeToPro", defaultValue: "Upgrade to cmux Pro…"),
                to: menu
            ) {
                ProUpgradePresenter.present()
            }
#if DEBUG
            addAction(
                String(
                    localized: "menu.help.previewNativePricing",
                    defaultValue: "Preview Native Pro Pricing…"
                ),
                to: menu
            ) {
                ProUpgradePresenter.presentNativePricingPreview()
            }
#endif
        }
#if DEBUG
        addAction(
            String(
                localized: "menu.help.showProWelcomeChecklist",
                defaultValue: "Show Pro Welcome Checklist…"
            ),
            to: menu
        ) {
            ProWelcomeChecklistPresenter.present()
        }
        addAction(
            String(localized: "menu.help.featureFlags", defaultValue: "Feature Flags…"),
            to: menu
        ) {
            InternalFlagsPresenter.present()
        }
        addAction(
            String(
                localized: "debug.menu.sidebarFooterIconBalance",
                defaultValue: "Footer Icon Balance Lab…"
            ),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.debugWindowsCoordinator.showSidebarFooterIconBalanceWindow()
        }
#endif

        addSeparator(to: menu)
        addAction(
            String(
                localized: "menu.help.keyboardShortcutsSettings",
                defaultValue: "Keyboard Shortcuts Settings…"
            ),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.openPreferencesWindow(
                debugSource: "nativeHelpMenu.keyboardShortcuts",
                navigationTarget: .keyboardShortcuts
            )
        }
    }

    private func addHelpResource(_ resource: CmuxHelpResource, to menu: NSMenu) {
        addAction(resource.title, to: menu) {
            NSWorkspace.shared.open(resource.url)
        }
    }

    private func presentFeedback() {
        if let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            FeedbackComposerBridge().openComposer(in: targetWindow)
            return
        }
        if let targetWindow = appDelegate?.showMainWindowFromMenuBar() {
            FeedbackComposerBridge().openComposer(in: targetWindow)
        }
    }

    private func buildUpdatePillMenu(_ menu: NSMenu) {
#if DEBUG
        addAction(
            String(localized: "debug.updatePill.show", defaultValue: "Show Update Pill"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.showUpdatePill(nil)
        }
        addAction(
            String(localized: "debug.updatePill.showLongNightly", defaultValue: "Show Long Nightly Pill"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.showUpdatePillLongNightly(nil)
        }
        addAction(
            String(localized: "debug.updatePill.showLoading", defaultValue: "Show Loading State"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.showUpdatePillLoading(nil)
        }
        let errorMenu = addSubmenu(
            String(localized: "debug.updatePill.showError", defaultValue: "Show Update Error…"),
            to: menu
        )
        for scenario in DebugUpdateErrorScenario.allCases {
            addAction(scenario.menuTitle, to: errorMenu) { [weak self] in
                self?.appDelegate?.updateViewModel.debugShowUpdateError(scenario)
            }
        }
        addAction(
            String(localized: "debug.updatePill.hide", defaultValue: "Hide Update Pill"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.hideUpdatePill(nil)
        }
        addAction(
            String(localized: "debug.updatePill.automatic", defaultValue: "Automatic Update Pill"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.clearUpdatePillOverride(nil)
        }
#endif
    }

    private func buildDebugMenu(_ menu: NSMenu) {
#if DEBUG
        addAction(
            String(localized: "debug.menu.newLoremTab", defaultValue: "New Tab With Lorem Search Text"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.openDebugLoremTab(nil)
        }
        addAction(
            String(localized: "debug.menu.newLargeScrollback", defaultValue: "New Tab With Large Scrollback"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.openDebugScrollbackTab(nil)
        }
        buildIrohDebugMenu(addSubmenu(
            String(localized: "debug.menu.irohTransport", defaultValue: "Iroh Transport"),
            to: menu
        ))
        addAction(
            String(localized: "debug.menu.openAgentGuiReact", defaultValue: "Open Agent GUI (React)"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.openDebugAgentSessionReact(nil)
        }
        addAction(
            String(localized: "debug.menu.openAgentGuiSolid", defaultValue: "Open Agent GUI (Solid)"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.openDebugAgentSessionSolid(nil)
        }
        addAction(
            String(
                localized: "debug.menu.openWorkspaceColors",
                defaultValue: "Open Workspaces for All Workspace Colors"
            ),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.openDebugColorComparisonWorkspaces(nil)
        }
        addAction(
            String(
                localized: "debug.menu.openStressWorkspacesWithLoadedSurfaces",
                defaultValue: "Open Stress Workspaces and Load All Terminals"
            ),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.openDebugStressWorkspacesWithLoadedSurfaces(nil)
        }

        addSeparator(to: menu)
        let windows = addSubmenu(
            String(localized: "debug.menu.windows", defaultValue: "Debug Windows"),
            to: menu
        )
        addDebugWindowItems(to: windows)

        addSeparator(to: menu)
        addAction(
            String(localized: "menu.updateLogs.copyUpdateLogs", defaultValue: "Copy Update Logs"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.copyUpdateLogs(nil)
        }
        addAction(
            String(localized: "menu.updateLogs.copyFocusLogs", defaultValue: "Copy Focus Logs"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.copyFocusLogs(nil)
        }
        addSeparator(to: menu)
        addAction(
            String(localized: "debug.menu.triggerSentryCrash", defaultValue: "Trigger Sentry Test Crash"),
            to: menu
        ) { [weak self] in
            self?.appDelegate?.triggerSentryTestCrash(nil)
        }
#endif
    }

    private func buildIrohDebugMenu(_ menu: NSMenu) {
#if DEBUG
        let stored = UserDefaults.standard.string(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        let selected = CmxIrohTransportVerificationMode(rawValue: stored ?? "") ?? .automatic
        let choices: [(CmxIrohTransportVerificationMode, String)] = [
            (
                .automatic,
                String(localized: "debug.menu.irohTransport.automatic", defaultValue: "Automatic")
            ),
            (
                .relayOnly,
                String(localized: "debug.menu.irohTransport.relayOnly", defaultValue: "Relay Only")
            ),
            (
                .directOnly,
                String(
                    localized: "debug.menu.irohTransport.noRelay",
                    defaultValue: "No Relay (Direct Only)"
                )
            ),
        ]
        for (mode, title) in choices {
            addAction(
                title,
                to: menu,
                state: selected == mode ? .on : .off
            ) {
                UserDefaults.standard.set(
                    mode.rawValue,
                    forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
                )
                Task { @MainActor in
                    await MobileHostIrohRuntime.shared.setIrohDebugTransportVerificationMode(mode)
                }
            }
        }
#endif
    }

    private func addDebugWindowItems(to menu: NSMenu) {
#if DEBUG
        let actions: [(String, () -> Void)] = [
            (String(localized: "debug.menu.background", defaultValue: "Background Debug…"), { BackgroundDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.proBadgeStyle", defaultValue: "Pro Badge Style…"), { ProBadgeDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.bonsplitTabBarDebug", defaultValue: "Bonsplit Tab Bar Debug…"), { BonsplitTabBarDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.browserImportHint", defaultValue: "Browser Import Hint Debug…"), { BrowserImportHintDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.browserProfilePopoverDebug", defaultValue: "Browser Profile Popover Debug…"), { BrowserProfilePopoverDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.windowControls", defaultValue: "Debug Window Controls…"), { DebugWindowControlsWindowController.shared.show() }),
            (String(localized: "debug.menu.feedPreview", defaultValue: "Feed Preview…"), { FeedPreviewWindowController.shared.show() }),
            (String(localized: "debug.menu.feedTextEditorDebug", defaultValue: "Feed Text Editor Lab…"), { FeedTextEditorDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.feedButtonStyleDebug", defaultValue: "Feed Button Style Debug…"), { FeedButtonStyleDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.startupAppearanceDebug", defaultValue: "Startup Appearance Debug…"), { StartupAppearanceDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.menuBarExtra", defaultValue: "Menu Bar Extra Debug…"), { MenuBarExtraDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.aboutTitlebarDebug", defaultValue: "About Titlebar Debug…"), { AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow() }),
            (String(localized: "debug.menu.titlebarLayoutDebug", defaultValue: "Titlebar Layout Debug..."), { TitlebarLayoutDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.sidebar", defaultValue: "Sidebar Debug…"), { SidebarDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.sidebarFooterIconBalance", defaultValue: "Footer Icon Balance Lab…"), { AppDelegate.shared?.debugWindowsCoordinator.showSidebarFooterIconBalanceWindow() }),
            (String(localized: "debug.menu.splitButtonLayoutDebug", defaultValue: "Split Button Layout Debug…"), { SplitButtonLayoutDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.tabBarBackdropLab", defaultValue: "Tab Bar Backdrop Lab…"), { TabBarBackdropLabWindowController.shared.show() }),
            (String(localized: "debug.menu.fileExplorerStyle", defaultValue: "File Explorer Style Debug…"), { FileExplorerStyleDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.pdfPreviewChromeDebug", defaultValue: "PDF Preview Chrome Debug…"), { PDFPreviewChromeDebugWindowController.shared.show() }),
        ]
        for (title, handler) in actions {
            addAction(title, to: menu, handler: handler)
        }
        addAction(
            String(localized: "debug.menu.openAllWindows", defaultValue: "Open All Debug Windows"),
            to: menu
        ) {
            for (_, handler) in actions {
                handler()
            }
        }
#endif
    }
}
