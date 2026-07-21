import AppKit
import Bonsplit
import CmuxSettings

private struct DockPaneCloseConfirmationPrompt: Sendable {
    let title: String
    let message: String
    let details: String

    init(titles: [String]) {
        let count = titles.count
        let titleLines = titles.map { "• \($0)" }.joined(separator: "\n")
        details = titleLines
        title = String(localized: "dialog.closePane.title", defaultValue: "Close pane?")

        if count == 1 {
            let format = String(
                localized: "dialog.closePane.message.one",
                defaultValue: "This will close 1 tab in this pane:\n%@"
            )
            message = String(format: format, locale: .current, titleLines)
        } else {
            let format = String(
                localized: "dialog.closePane.message.other",
                defaultValue: "This will close %1$lld tabs in this pane:\n%2$@"
            )
            message = String(format: format, locale: .current, Int64(count), titleLines)
        }
    }
}

extension DockSplitStore {
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        let tabCloseButtonClose = tabCloseButtonCloseDockTabIds.remove(tab.id) != nil
        guard let panel = panel(for: tab.id) else { return true }
        if let note = panel as? FilePreviewPanel,
           note.needsAutosaveFlush {
            guard pendingAutosaveCloseDockTabIds.insert(tab.id).inserted else { return false }
            if tabCloseButtonClose {
                tabCloseButtonCloseDockTabIds.insert(tab.id)
            }
            let tabId = tab.id
            Task { @MainActor [weak self, weak note] in
                guard let self, let note else { return }
                let saved = await note.flushPendingAutosave()
                self.pendingAutosaveCloseDockTabIds.remove(tabId)
                guard saved, self.panel(for: tabId) != nil else {
                    self.forceCloseDockTabIds.remove(tabId)
                    NSSound.beep()
                    return
                }
                _ = self.bonsplitController.closeTab(tabId)
            }
            return false
        }
        if forceCloseDockTabIds.contains(tab.id) {
            return true
        }

        let closeSource: CloseTabCloseSource = tabCloseButtonClose ? .tabCloseButton : .shortcut
        guard CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
            requiresConfirmation: dockPanelNeedsConfirmClose(panel),
            source: closeSource
        ) else {
            return true
        }
        guard !pendingCloseConfirmDockTabIds.contains(tab.id) else { return false }

        let confirmationManager = dockCloseConfirmationManager()
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
        let paneTabs = controller.tabs(inPane: pane)
        let notesToFlush = paneTabs.compactMap { tab -> FilePreviewPanel? in
            guard let note = panel(for: tab.id) as? FilePreviewPanel,
                  note.needsAutosaveFlush else { return nil }
            return note
        }
        if !notesToFlush.isEmpty {
            guard pendingAutosaveCloseDockPaneIds.insert(pane.id).inserted else { return false }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var saved = true
                for note in notesToFlush where saved {
                    saved = await note.flushPendingAutosave()
                }
                self.pendingAutosaveCloseDockPaneIds.remove(pane.id)
                guard saved else {
                    self.forceCloseDockTabIds.subtract(paneTabs.map(\.id))
                    NSSound.beep()
                    return
                }
                _ = self.bonsplitController.closePane(pane)
            }
            return false
        }
        var paneTitles: [String] = []
        var confirmableTabIds = Set<TabID>()
        for tab in paneTabs {
            let panel = panel(for: tab.id)
            paneTitles.append(CloseOtherTabsConfirmationPrompt.displayTitle(panel?.displayTitle ?? tab.title))
            guard !forceCloseDockTabIds.contains(tab.id), let panel else { continue }
            if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                requiresConfirmation: dockPanelNeedsConfirmClose(panel),
                source: .shortcut
            ) {
                confirmableTabIds.insert(tab.id)
            }
        }
        guard !confirmableTabIds.isEmpty else { return true }

        guard pendingCloseConfirmDockTabIds.isDisjoint(with: confirmableTabIds) else { return false }

        let confirmationManager = dockCloseConfirmationManager()
        if confirmationManager?.isCloseConfirmationInFlight == true { return false }

        pendingCloseConfirmDockTabIds.formUnion(confirmableTabIds)
        let prompt = DockPaneCloseConfirmationPrompt(titles: paneTitles)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingCloseConfirmDockTabIds.subtract(confirmableTabIds) }
            guard self.confirmCloseDockPane(prompt, confirmationManager: confirmationManager) else { return }

            self.forceCloseDockTabIds.formUnion(confirmableTabIds)
            defer { self.forceCloseDockTabIds.subtract(confirmableTabIds) }
            _ = self.bonsplitController.closePane(pane)
        }
        return false
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        forceCloseDockTabIds.remove(tabId)
        pendingCloseConfirmDockTabIds.remove(tabId)
        pendingAutosaveCloseDockTabIds.remove(tabId)
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

    /// The manager that owns Dock close confirmation state and sheet
    /// presentation. Window Docks use a window id as `workspaceId`, so they
    /// must resolve through the Dock owner rather than `tabManagerFor(tabId:)`.
    private func dockCloseConfirmationManager() -> TabManager? {
        guard let app = AppDelegate.shared else { return nil }
        return app.dockReferenceTabManager(for: self)
    }

    func needsConfirmClose() -> Bool {
        for tabId in bonsplitController.allTabIds {
            guard let panel = panel(for: tabId), dockPanelNeedsConfirmClose(panel) else { continue }
            return true
        }
        return false
    }

    func confirmCloseAllPanels() -> Bool {
        Self.confirmCloseAllPanels(
            in: [self],
            confirmationManager: dockCloseConfirmationManager()
        )
    }

    static func confirmCloseAllPanels(
        in stores: [DockSplitStore],
        confirmationManager: TabManager?
    ) -> Bool {
        var panelsToClose: [any Panel] = []
        var shouldConfirm = false
        for store in stores {
            let storePanels = store.bonsplitController.allTabIds.compactMap { store.panel(for: $0) }
            panelsToClose.append(contentsOf: storePanels)
            if !shouldConfirm {
                shouldConfirm = storePanels.contains { panel in
                    CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                        requiresConfirmation: store.dockPanelNeedsConfirmClose(panel),
                        source: .shortcut
                    )
                }
            }
        }
        guard shouldConfirm else { return true }
        let prompt = DockPaneCloseConfirmationPrompt(
            titles: panelsToClose.map { CloseOtherTabsConfirmationPrompt.displayTitle($0.displayTitle) }
        )
        guard let presenter = stores.first else { return true }
        return presenter.confirmCloseDockPane(prompt, confirmationManager: confirmationManager)
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
        confirmCloseDockPrompt(
            title: prompt.title,
            message: prompt.message,
            scrollableDetails: prompt.details,
            confirmationManager: confirmationManager
        )
    }

    private func confirmCloseDockPrompt(
        title: String,
        message: String,
        scrollableDetails: String? = nil,
        confirmationManager: TabManager?
    ) -> Bool {
        if let confirmationManager {
            return confirmationManager.confirmClose(
                title: title,
                message: message,
                scrollableDetails: scrollableDetails,
                acceptCmdD: false
            )
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))
        let content = scrollableDetails.map {
            CmuxAlertContent(flattenedText: message, separatingScrollableDetails: $0)
        } ?? CmuxAlertContent(informativeText: message)
        return alert.runCmuxModal(content: content) == .alertFirstButtonReturn
    }
}
