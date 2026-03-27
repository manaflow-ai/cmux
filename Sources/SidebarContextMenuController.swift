import AppKit
import Bonsplit
import SwiftUI

/// NSMenuItem subclass that routes actions through a closure.
private final class ActionMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, isEnabled: Bool = true, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(performAction), keyEquivalent: "")
        self.handler = handler
        self.target = self
        self.isEnabled = isEnabled
    }

    @objc private func performAction() {
        handler?()
    }
}

/// Builds the workspace sidebar context menu at right-click time via NSMenuDelegate.
/// Menu items are constructed in menuNeedsUpdate(_:) and remain static while open,
/// fully decoupled from the SwiftUI rendering pipeline.
@MainActor
final class SidebarContextMenuController: NSObject, NSMenuDelegate {
    var workspace: Workspace?
    var tabManager: TabManager?
    var notificationStore: TerminalNotificationStore?
    var index: Int = 0
    var depth: Int = 0
    var readSelectedTabIds: () -> Set<UUID> = { [] }
    var writeSelectedTabIds: (Set<UUID>) -> Void = { _ in }
    var readLastSidebarSelectionIndex: () -> Int? = { nil }
    var writeLastSidebarSelectionIndex: (Int?) -> Void = { _ in }
    var setSelectionToTabs: (() -> Void)?

    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            populateMenu(menu)
        }
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let workspace, let tabManager else { return }
#if DEBUG
        dlog("contextMenu.menuNeedsUpdate workspace=\(workspace.id.uuidString.prefix(5))")
#endif
        let targetIds = contextTargetIds()
        let isMulti = targetIds.count > 1

        addPinItem(to: menu, targetIds: targetIds, isMulti: isMulti)
        addRenameItems(to: menu)
        addRemoteItems(to: menu, targetIds: targetIds, isMulti: isMulti)
        addColorSubmenu(to: menu, targetIds: targetIds)
        addCopySSHErrorItem(to: menu)
        menu.addItem(.separator())
        addScriptSubmenu(to: menu)
        addTemplateSubmenu(to: menu)
        addHierarchyItems(to: menu)
        menu.addItem(.separator())
        addMoveItems(to: menu, targetIds: targetIds, isMulti: isMulti)
        menu.addItem(.separator())
        addCloseItems(to: menu, targetIds: targetIds, isMulti: isMulti)
        menu.addItem(.separator())
        addNotificationItems(to: menu, targetIds: targetIds, isMulti: isMulti)
    }

    // MARK: - Target Resolution

    private func contextTargetIds() -> [UUID] {
        guard let tabManager, let workspace else { return [] }
        let selectedIds = readSelectedTabIds()
        let baseIds: Set<UUID> = selectedIds.contains(workspace.id) ? selectedIds : [workspace.id]
        return tabManager.tabs.compactMap { baseIds.contains($0.id) ? $0.id : nil }
    }

    private func label(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    // MARK: - Pin

    private func addPinItem(to menu: NSMenu, targetIds: [UUID], isMulti: Bool) {
        guard let workspace, let tabManager else { return }
        let shouldPin = !workspace.isPinned
        let title = shouldPin
            ? label(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : label(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        menu.addItem(ActionMenuItem(title) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            for id in targetIds {
                if let tab = tabManager.tabs.first(where: { $0.id == id }) {
                    tabManager.setPinned(tab, pinned: shouldPin)
                }
            }
            self.syncSelectionAfterMutation()
        })
    }

    // MARK: - Rename

    private func addRenameItems(to menu: NSMenu) {
        guard let workspace else { return }
        menu.addItem(ActionMenuItem(
            String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")
        ) { [weak self] in
            self?.promptRename()
        })
        if workspace.hasCustomTitle {
            menu.addItem(ActionMenuItem(
                String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")
            ) { [weak self] in
                self?.tabManager?.clearCustomTitle(tabId: workspace.id)
            })
        }
    }

    // MARK: - Remote

    private func addRemoteItems(to menu: NSMenu, targetIds: [UUID], isMulti: Bool) {
        guard let tabManager else { return }
        let remoteTargets = tabManager.tabs.filter { targetIds.contains($0.id) && $0.isRemoteWorkspace }
        guard !remoteTargets.isEmpty else { return }
        menu.addItem(.separator())
        let allConnecting = remoteTargets.allSatisfy { $0.remoteConnectionState == .connecting }
        let allDisconnected = remoteTargets.allSatisfy { $0.remoteConnectionState == .disconnected }
        menu.addItem(ActionMenuItem(
            label(
                multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
                single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
                isMulti: isMulti),
            isEnabled: !allConnecting
        ) {
            for workspace in remoteTargets { workspace.reconnectRemoteConnection() }
        })
        menu.addItem(ActionMenuItem(
            label(
                multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
                single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
                isMulti: isMulti),
            isEnabled: !allDisconnected
        ) {
            for workspace in remoteTargets { workspace.disconnectRemoteConnection(clearConfiguration: false) }
        })
    }

    // MARK: - Color Submenu

    private func addColorSubmenu(to menu: NSMenu, targetIds: [UUID]) {
        guard let workspace, let tabManager else { return }
        let colorMenu = NSMenu()
        let parentItem = NSMenuItem(title: String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color"), action: nil, keyEquivalent: "")
        parentItem.submenu = colorMenu

        if workspace.customColor != nil {
            colorMenu.addItem(ActionMenuItem(
                String(localized: "contextMenu.clearColor", defaultValue: "Clear Color")
            ) { [weak tabManager] in
                for id in targetIds { tabManager?.setTabColor(tabId: id, color: nil) }
            })
        }
        colorMenu.addItem(ActionMenuItem(
            String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…")
        ) { [weak self] in
            self?.promptCustomColor(targetIds: targetIds)
        })

        let palette = WorkspaceTabColorSettings.palette()
        if !palette.isEmpty { colorMenu.addItem(.separator()) }
        for entry in palette {
            let item = ActionMenuItem(entry.name) { [weak tabManager] in
                for id in targetIds { tabManager?.setTabColor(tabId: id, color: entry.hex) }
            }
            item.image = colorSwatchImage(hex: entry.hex)
            colorMenu.addItem(item)
        }
        menu.addItem(parentItem)
    }

    // MARK: - SSH Error

    private func addCopySSHErrorItem(to menu: NSMenu) {
        guard let workspace else { return }
        guard let errorText = copyableSSHError(for: workspace) else { return }
        menu.addItem(ActionMenuItem(
            String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")
        ) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(errorText, forType: .string)
        })
    }

    // MARK: - Script Submenu

    private func addScriptSubmenu(to menu: NSMenu) {
        guard let workspace else { return }
        let scriptMenu = NSMenu()
        let parentItem = NSMenuItem(
            title: String(localized: "contextMenu.runScript", defaultValue: "Run Script"),
            action: nil, keyEquivalent: "")
        parentItem.submenu = scriptMenu

        let isAtPrompt = workspace.isFocusedPanelAtPrompt
        let scripts = ScriptRepository.shared.listScripts()
        for scriptName in scripts {
            scriptMenu.addItem(ActionMenuItem(scriptName, isEnabled: isAtPrompt) { [weak workspace] in
                guard let workspace,
                      let content = ScriptRepository.shared.getScript(named: scriptName),
                      let terminal = workspace.focusedTerminalPanel else { return }
                let lines = StartupScriptRunner.prepareScriptLines(content)
                guard !lines.isEmpty else { return }
                terminal.sendInteractiveText(lines.joined(separator: "\n") + "\n")
            })
        }
        if !scripts.isEmpty { scriptMenu.addItem(.separator()) }
        scriptMenu.addItem(ActionMenuItem(
            String(localized: "contextMenu.openScriptsFolder", defaultValue: "Open Scripts Folder…")
        ) {
            NSWorkspace.shared.open(ScriptRepository.shared.directory)
        })
        menu.addItem(parentItem)
    }

    // MARK: - Template Submenu

    private func addTemplateSubmenu(to menu: NSMenu) {
        guard let workspace, let tabManager else { return }
        let templateMenu = NSMenu()
        let parentItem = NSMenuItem(
            title: String(localized: "contextMenu.openTemplate", defaultValue: "Open Template"),
            action: nil, keyEquivalent: "")
        parentItem.submenu = templateMenu

        let hasTerminal = workspace.focusedTerminalPanel != nil
        let templates = TemplateRepository.shared.listTemplates()
        for templateName in templates {
            templateMenu.addItem(ActionMenuItem(templateName, isEnabled: hasTerminal) { [weak workspace, weak tabManager] in
                guard let workspace, let tabManager,
                      let template = try? TemplateRepository.shared.getTemplate(named: templateName) else { return }
                tabManager.openTemplate(template, directory: workspace.currentDirectory)
            })
        }
        if !templates.isEmpty { templateMenu.addItem(.separator()) }
        templateMenu.addItem(ActionMenuItem(
            String(localized: "contextMenu.openTemplatesFolder", defaultValue: "Open Templates Folder…")
        ) {
            NSWorkspace.shared.open(TemplateRepository.shared.directory)
        })
        menu.addItem(parentItem)
    }

    // MARK: - Hierarchy

    private func addHierarchyItems(to menu: NSMenu) {
        guard let workspace, let tabManager else { return }
        if depth < 2 {
            menu.addItem(ActionMenuItem(
                String(localized: "contextMenu.addChildWorkspace", defaultValue: "Add Child Workspace")
            ) { [weak tabManager] in
                tabManager?.addChildWorkspace(for: workspace.id)
            })
        }
        let canMakeChild = computeCanMakeChild()
        menu.addItem(ActionMenuItem(
            String(localized: "contextMenu.makeChild", defaultValue: "Make Child"),
            isEnabled: canMakeChild
        ) { [weak tabManager] in
            guard let tabManager else { return }
            if tabManager.groupManager.indentWorkspace(workspace.id) {
                tabManager.items = tabManager.groupManager.items
            }
        })
        if depth > 0 {
            menu.addItem(ActionMenuItem(
                String(localized: "contextMenu.raiseLevel", defaultValue: "Raise Level")
            ) { [weak tabManager] in
                guard let tabManager else { return }
                if tabManager.groupManager.outdentWorkspace(workspace.id) {
                    tabManager.items = tabManager.groupManager.items
                }
            })
        }
    }

    // MARK: - Move

    private func addMoveItems(to menu: NSMenu, targetIds: [UUID], isMulti: Bool) {
        guard let workspace, let tabManager else { return }
        menu.addItem(ActionMenuItem(
            String(localized: "contextMenu.moveUp", defaultValue: "Move Up"),
            isEnabled: index > 0
        ) { [weak self] in
            self?.moveBy(-1)
        })
        menu.addItem(ActionMenuItem(
            String(localized: "contextMenu.moveDown", defaultValue: "Move Down"),
            isEnabled: index < tabManager.tabs.count - 1
        ) { [weak self] in
            self?.moveBy(1)
        })
        menu.addItem(ActionMenuItem(
            String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"),
            isEnabled: !targetIds.isEmpty
        ) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            tabManager.moveTabsToTop(Set(targetIds))
            self.syncSelectionAfterMutation()
        })

        // Move to Window submenu
        let windowMenu = NSMenu()
        let moveTitle = label(
            multi: String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window"),
            single: String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window"),
            isMulti: isMulti)
        let moveParent = NSMenuItem(title: moveTitle, action: nil, keyEquivalent: "")
        moveParent.submenu = windowMenu
        moveParent.isEnabled = !targetIds.isEmpty

        windowMenu.addItem(ActionMenuItem(
            String(localized: "contextMenu.newWindow", defaultValue: "New Window"),
            isEnabled: !targetIds.isEmpty
        ) { [weak self] in
            self?.moveWorkspacesToNewWindow(targetIds)
        })
        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        if !windowTargets.isEmpty { windowMenu.addItem(.separator()) }
        for target in windowTargets {
            windowMenu.addItem(ActionMenuItem(
                target.label,
                isEnabled: !target.isCurrentWindow && !targetIds.isEmpty
            ) { [weak self] in
                self?.moveWorkspaces(targetIds, toWindow: target.windowId)
            })
        }
        menu.addItem(moveParent)
    }

    // MARK: - Close

    private func addCloseItems(to menu: NSMenu, targetIds: [UUID], isMulti: Bool) {
        guard let workspace, let tabManager else { return }
        let closeTitle = label(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        menu.addItem(ActionMenuItem(closeTitle, isEnabled: !targetIds.isEmpty) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            tabManager.closeWorkspacesWithConfirmation(targetIds, allowPinned: true)
            self.syncSelectionAfterMutation()
        })
        menu.addItem(ActionMenuItem(
            String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces"),
            isEnabled: tabManager.tabs.count > 1 && targetIds.count < tabManager.tabs.count
        ) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            let keepIds = Set(targetIds)
            let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
            tabManager.closeWorkspacesWithConfirmation(idsToClose, allowPinned: false)
            self.syncSelectionAfterMutation()
        })
        menu.addItem(ActionMenuItem(
            String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below"),
            isEnabled: index < tabManager.tabs.count - 1
        ) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            guard let anchor = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else { return }
            let ids = tabManager.tabs.suffix(from: anchor + 1).map(\.id)
            tabManager.closeWorkspacesWithConfirmation(ids, allowPinned: false)
            self.syncSelectionAfterMutation()
        })
        menu.addItem(ActionMenuItem(
            String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above"),
            isEnabled: index > 0
        ) { [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            guard let anchor = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else { return }
            let ids = tabManager.tabs.prefix(upTo: anchor).map(\.id)
            tabManager.closeWorkspacesWithConfirmation(ids, allowPinned: false)
            self.syncSelectionAfterMutation()
        })
    }

    // MARK: - Notifications

    private func addNotificationItems(to menu: NSMenu, targetIds: [UUID], isMulti: Bool) {
        guard let notificationStore else { return }
        let targetSet = Set(targetIds)
        let hasUnread = notificationStore.notifications.contains { targetSet.contains($0.tabId) && !$0.isRead }
        let hasRead = notificationStore.notifications.contains { targetSet.contains($0.tabId) && $0.isRead }
        menu.addItem(ActionMenuItem(
            label(
                multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
                single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
                isMulti: isMulti),
            isEnabled: hasUnread
        ) { [weak notificationStore] in
            for id in targetIds { notificationStore?.markRead(forTabId: id) }
        })
        menu.addItem(ActionMenuItem(
            label(
                multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
                single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
                isMulti: isMulti),
            isEnabled: hasRead
        ) { [weak notificationStore] in
            for id in targetIds { notificationStore?.markUnread(forTabId: id) }
        })
    }
}
