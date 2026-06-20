import AppKit
import Bonsplit
import CmuxSettings

private struct DockPaneCloseConfirmationPrompt: Sendable {
    let title: String
    let message: String

    init(titles: [String]) {
        let count = titles.count
        let titleLines = titles.map { "• \($0)" }.joined(separator: "\n")
        title = String(localized: "dialog.closePane.title", defaultValue: "Close pane?")

        if count == 1 {
            let format = String(
                localized: "dialog.closeOtherTabs.message.one",
                defaultValue: "This will close 1 tab in this pane:\n%@"
            )
            message = String(format: format, locale: .current, titleLines)
        } else {
            let format = String(
                localized: "dialog.closeOtherTabs.message.other",
                defaultValue: "This will close %1$lld tabs in this pane:\n%2$@"
            )
            message = String(format: format, locale: .current, Int64(count), titleLines)
        }
    }
}

extension DockSplitStore {
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        if forceCloseDockTabIds.contains(tab.id) {
            return true
        }

        let tabCloseButtonClose = tabCloseButtonCloseDockTabIds.remove(tab.id) != nil
        let closeSource: CloseTabCloseSource = tabCloseButtonClose ? .tabCloseButton : .shortcut
        guard let panel = panel(for: tab.id) else { return true }
        guard CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
            requiresConfirmation: dockPanelNeedsConfirmClose(panel),
            source: closeSource
        ) else {
            return true
        }
        guard !pendingCloseConfirmDockTabIds.contains(tab.id) else { return false }

        let confirmationManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) ?? AppDelegate.shared?.tabManager
        if confirmationManager?.isCloseConfirmationInFlight == true { return false }

        pendingCloseConfirmDockTabIds.insert(tab.id)
        let tabId = tab.id
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.pendingCloseConfirmDockTabIds.remove(tabId)
            }
            guard let panel = self.panel(for: tabId) else { return }
            guard self.confirmCloseDockPanel(panel, confirmationManager: confirmationManager) else { return }

            self.forceCloseDockTabIds.insert(tabId)
            let closed = self.bonsplitController.closeTab(tabId)
            if !closed {
                self.forceCloseDockTabIds.remove(tabId)
            }
        }
        return false
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        let confirmableTabs = controller.tabs(inPane: pane).compactMap { tab -> (id: TabID, title: String)? in
            guard !forceCloseDockTabIds.contains(tab.id), let panel = panel(for: tab.id) else { return nil }
            guard CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                requiresConfirmation: dockPanelNeedsConfirmClose(panel),
                source: .shortcut
            ) else { return nil }
            return (tab.id, CloseOtherTabsConfirmationPrompt.displayTitle(panel.displayTitle))
        }
        guard !confirmableTabs.isEmpty else { return true }

        let tabIds = Set(confirmableTabs.map { $0.id })
        guard pendingCloseConfirmDockTabIds.isDisjoint(with: tabIds) else { return false }

        let confirmationManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) ?? AppDelegate.shared?.tabManager
        if confirmationManager?.isCloseConfirmationInFlight == true { return false }

        pendingCloseConfirmDockTabIds.formUnion(tabIds)
        let prompt = DockPaneCloseConfirmationPrompt(titles: confirmableTabs.map { $0.title })
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingCloseConfirmDockTabIds.subtract(tabIds) }
            guard self.confirmCloseDockPane(prompt, confirmationManager: confirmationManager) else { return }

            self.forceCloseDockTabIds.formUnion(tabIds)
            defer { self.forceCloseDockTabIds.subtract(tabIds) }
            _ = self.bonsplitController.closePane(pane)
        }
        return false
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        forceCloseDockTabIds.remove(tabId)
        pendingCloseConfirmDockTabIds.remove(tabId)
        tabCloseButtonCloseDockTabIds.remove(tabId)
        reconcilePanels()
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        reconcilePanels()
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        let surfaceKind: DockSurfaceKind = (kind == "browser") ? .browser : .terminal
        _ = newSurface(kind: surfaceKind, inPane: pane, focus: true)
    }

    private func dockPanelNeedsConfirmClose(_ panel: any Panel) -> Bool {
        if let terminalPanel = panel as? TerminalPanel {
            return terminalPanel.needsConfirmClose()
        }
        return panel.isDirty
    }

    private func confirmCloseDockPanel(_ panel: any Panel, confirmationManager: TabManager?) -> Bool {
        let title = String(localized: "dialog.closeTab.title", defaultValue: "Close tab?")
        let panelName = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        if !panelName.isEmpty {
            message = String(localized: "dialog.closeTab.messageNamed", defaultValue: "This will close \"\(panelName)\".")
        } else {
            message = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        }
        return confirmCloseDockPrompt(title: title, message: message, confirmationManager: confirmationManager)
    }

    private func confirmCloseDockPane(_ prompt: DockPaneCloseConfirmationPrompt, confirmationManager: TabManager?) -> Bool {
        confirmCloseDockPrompt(title: prompt.title, message: prompt.message, confirmationManager: confirmationManager)
    }

    private func confirmCloseDockPrompt(title: String, message: String, confirmationManager: TabManager?) -> Bool {
        if let confirmationManager {
            return confirmationManager.confirmClose(title: title, message: message, acceptCmdD: false)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
