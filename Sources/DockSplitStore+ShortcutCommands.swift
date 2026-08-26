import AppKit
import Bonsplit
import CmuxPanes
import CmuxSettings
import CmuxTerminal
import CmuxWorkspaces
import Foundation

enum DockShortcutCommand {
    case selectNextSurface
    case selectPreviousSurface
    case selectSurface(number: Int)
    case moveSurface(offset: Int)
    case moveSurfaceToPane(
        SurfacePaneMovement,
        allowMissingDestinationSplit: Bool
    )
    case focusPane(NavigationDirection)
    case cyclePaneFocus(forward: Bool)
    case togglePaneZoom
    case equalizeSplits
    case focusHistoryBack
    case focusHistoryForward
    case triggerFlash
    case renameSurface(presentingWindow: NSWindow?)
    case closeOtherTabsInPane
    case toggleTerminalCopyMode
    case focusTextBoxInput
    case attachTextBoxFile
    case sendCtrlFToTerminal
    case clearScreenKeepScrollback
    case startFind
    case findNext
    case findPrevious
    case hideFind
    case useSelectionForFind
    case toggleReactGrab
    case reopenClosedPanel

    var isFocusHistoryNavigation: Bool {
        switch self {
        case .focusHistoryBack, .focusHistoryForward:
            true
        default:
            false
        }
    }
}

extension DockSplitStore {
    /// Executes surface and focus commands against the Dock's own Bonsplit tree.
    /// AppDelegate resolves configured key bindings and sends only the semantic
    /// command here, keeping every Dock entrypoint on the same ownership path.
    @discardableResult
    func performShortcutCommand(_ command: DockShortcutCommand) -> Bool {
        guard !isRetired else { return false }
        switch command {
        case .selectNextSurface:
            bonsplitController.selectNextTab()
            applyFocusedShortcutSelection()
            return true
        case .selectPreviousSurface:
            bonsplitController.selectPreviousTab()
            applyFocusedShortcutSelection()
            return true
        case .selectSurface(let number):
            return selectDockSurface(number: number)
        case .moveSurface(let offset):
            return moveSelectedDockSurface(by: offset)
        case let .moveSurfaceToPane(
            movement,
            allowMissingDestinationSplit
        ):
            return moveFocusedDockSurface(
                to: movement,
                allowMissingDestinationSplit:
                    allowMissingDestinationSplit
            )
        case .focusPane(let direction):
            bonsplitController.navigateFocus(direction: direction)
            applyFocusedShortcutSelection()
            return true
        case .cyclePaneFocus(let forward):
            return cycleDockPaneFocus(forward: forward)
        case .togglePaneZoom:
            guard let pane = bonsplitController.focusedPaneId else { return false }
            return toggleDockPaneZoom(inPane: pane)
        case .equalizeSplits:
            let result = PaneLayoutService().equalizeSplits(
                in: bonsplitController.treeSnapshot(),
                controller: bonsplitController
            )
            return result.foundSplit && result.allSucceeded
        case .focusHistoryBack:
            return focusHistoryNavigation.navigateBack()
        case .focusHistoryForward:
            return focusHistoryNavigation.navigateForward()
        case .triggerFlash:
            guard let focusedPanelId else { return false }
            triggerUserInitiatedFocusFlash(panelId: focusedPanelId)
            return true
        case .renameSurface(let presentingWindow):
            return promptRenameFocusedDockSurface(
                presentingWindow: presentingWindow
            )
        case .closeOtherTabsInPane:
            return closeOtherDockTabsInFocusedPane()
        case .toggleTerminalCopyMode:
            guard let terminal = focusedDockTerminalPanel else {
                return false
            }
            return terminal.surface.toggleKeyboardCopyMode()
        case .focusTextBoxInput:
            return focusedDockTerminalPanel?
                .focusTextBoxInputOrTerminal() ?? false
        case .attachTextBoxFile:
            return focusedDockTerminalPanel?
                .attachFileToTextBoxInput() ?? false
        case .sendCtrlFToTerminal:
            guard let terminal = focusedDockTerminalPanel else {
                return false
            }
            let result = terminal.sendNamedKeyResult("ctrl-f")
            if result == .sent {
                terminal.surface.forceRefresh(
                    reason: "dock.sendCtrlFToFocusedTerminal"
                )
            }
            return result.accepted
        case .clearScreenKeepScrollback:
            guard let terminal = focusedDockTerminalPanel else {
                return false
            }
            let didClear = terminal.clearScreenKeepingScrollback()
            if didClear {
                terminal.surface.forceRefresh(
                    reason: "dock.clearFocusedTerminalKeepingScrollback"
                )
            }
            return didClear
        case .startFind:
            return startDockFind()
        case .findNext:
            return performDockFindNavigation(.next)
        case .findPrevious:
            return performDockFindNavigation(.previous)
        case .hideFind:
            return hideDockFind()
        case .useSelectionForFind:
            return useDockSelectionForFind()
        case .toggleReactGrab:
            return toggleDockReactGrab()
        case .reopenClosedPanel:
            return reopenMostRecentlyClosedPanel()
        }
    }

    private func applyFocusedShortcutSelection() {
        guard let pane = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: pane),
              let panelId = surfaceIdToPanelId[tab.id] else { return }
        focusPanelFromDockInteraction(panelId, window: nil)
    }

    private func selectDockSurface(number: Int) -> Bool {
        guard let pane = bonsplitController.focusedPaneId else { return false }
        let tabs = bonsplitController.tabs(inPane: pane)
        let tab: Bonsplit.Tab?
        if number == 9 {
            tab = tabs.last
        } else if tabs.indices.contains(number - 1) {
            tab = tabs[number - 1]
        } else {
            tab = nil
        }
        guard let tab else { return true }
        bonsplitController.selectTab(tab.id)
        applyFocusedShortcutSelection()
        return true
    }

    private func moveSelectedDockSurface(by offset: Int) -> Bool {
        guard let pane = bonsplitController.focusedPaneId,
              let selectedTab = bonsplitController.selectedTab(inPane: pane) else { return false }
        let tabs = bonsplitController.tabs(inPane: pane)
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTab.id }), !tabs.isEmpty else {
            return false
        }
        let finalIndex = min(max(currentIndex + offset, tabs.startIndex), tabs.index(before: tabs.endIndex))
        guard finalIndex != currentIndex else { return true }
        let insertionIndex = finalIndex > currentIndex ? finalIndex + 1 : finalIndex
        return bonsplitController.reorderTab(selectedTab.id, toIndex: insertionIndex)
    }

    private var focusedDockTerminalPanel: TerminalPanel? {
        guard let focusedPanelId else { return nil }
        return panels[focusedPanelId] as? TerminalPanel
    }

    private var focusedDockBrowserPanel: BrowserPanel? {
        guard let focusedPanelId else { return nil }
        return panels[focusedPanelId] as? BrowserPanel
    }

    private func promptRenameFocusedDockSurface(
        presentingWindow: NSWindow?
    ) -> Bool {
        guard let panelId = focusedPanelId,
              let tabId = surfaceId(forPanelId: panelId) else {
            return false
        }
        return promptRenameDockSurface(
            tabId: tabId,
            presentingWindow: presentingWindow
        )
    }

    func promptRenameDockSurface(
        tabId: TabID,
        presentingWindow: NSWindow?
    ) -> Bool {
        guard let panel = panel(for: tabId),
              let tab = bonsplitController.tab(tabId) else {
            return false
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "alert.renameTab.title",
            defaultValue: "Rename Tab"
        )
        alert.informativeText = String(
            localized: "alert.renameTab.message",
            defaultValue: "Enter a custom name for this tab."
        )
        let input = NSTextField(string: tab.title)
        input.placeholderString = String(
            localized: "alert.renameTab.placeholder",
            defaultValue: "Tab name"
        )
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(
            withTitle: String(
                localized: "alert.renameTab.rename",
                defaultValue: "Rename"
            )
        )
        alert.addButton(
            withTitle: String(
                localized: "alert.cancel",
                defaultValue: "Cancel"
            )
        )
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        let response = alert.runCmuxModal(
            presentingWindow: presentingWindow
        ) { _ in
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        guard response == .alertFirstButtonReturn else { return true }

        return setDockPanelCustomTitle(
            panelId: panel.id,
            title: input.stringValue
        )
    }

    @discardableResult
    func setDockPanelCustomTitle(
        panelId: UUID,
        title: String?
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId),
              let panel = panels[panelId] else {
            return false
        }
        let customTitle = title?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        bonsplitController.updateTab(
            tabId,
            title: customTitle.isEmpty
                ? panel.displayTitle
                : customTitle,
            hasCustomTitle: !customTitle.isEmpty
        )
        return true
    }

    private func cycleDockPaneFocus(forward: Bool) -> Bool {
        let orderedPaneIds = bonsplitController.treeSnapshot()
            .orderedPaneIds
            .compactMap(UUID.init(uuidString:))
        guard let targetPaneId = PaneCycleNavigator().targetPane(
            orderedPaneIds: orderedPaneIds,
            livePaneIds: bonsplitController.allPaneIds,
            focusedPaneId: bonsplitController.focusedPaneId,
            forward: forward
        ) else {
            return false
        }
        bonsplitController.focusPane(targetPaneId)
        applyFocusedShortcutSelection()
        return true
    }

    private func moveFocusedDockSurface(
        to movement: SurfacePaneMovement,
        allowMissingDestinationSplit: Bool
    ) -> Bool {
        guard let panelId = focusedPanelId,
              let tabId = surfaceId(forPanelId: panelId),
              let sourcePaneId = paneId(forPanelId: panelId) else {
            return false
        }

        let destinationPaneId = dockDestinationPane(
            from: sourcePaneId,
            for: movement
        )
        let directionalSplit = allowMissingDestinationSplit
            ? dockDirectionalSplit(for: movement)
            : nil
        guard destinationPaneId != nil || directionalSplit != nil else {
            return false
        }

        let zoomedPaneId = bonsplitController.zoomedPaneId
        if let zoomedPaneId {
            _ = toggleDockPaneZoom(inPane: zoomedPaneId)
        }

        let didMove: Bool
        if let destinationPaneId {
            let destinationTabs =
                bonsplitController.tabs(inPane: destinationPaneId)
            let insertionIndex: Int
            if let selectedTabId = bonsplitController
                .selectedTab(inPane: destinationPaneId)?.id,
               let selectedIndex = destinationTabs.firstIndex(
                   where: { $0.id == selectedTabId }
               ) {
                insertionIndex = selectedIndex + 1
            } else {
                insertionIndex = destinationTabs.count
            }
            didMove = bonsplitController.moveTab(
                tabId,
                toPane: destinationPaneId,
                atIndex: insertionIndex
            )
            if didMove {
                bonsplitController.focusPane(destinationPaneId)
                bonsplitController.selectTab(tabId)
                applyFocusedShortcutSelection()
            }
        } else if let directionalSplit,
                  let newPaneId = bonsplitController.splitPane(
                      sourcePaneId,
                      orientation: directionalSplit.orientation,
                      movingTab: tabId,
                      insertFirst: directionalSplit.insertFirst
                  ) {
            bonsplitController.focusPane(newPaneId)
            bonsplitController.selectTab(tabId)
            applyFocusedShortcutSelection()
            didMove = true
        } else {
            didMove = false
        }

        if !didMove, let zoomedPaneId {
            _ = toggleDockPaneZoom(inPane: zoomedPaneId)
        }
        return didMove
    }

    private func dockDestinationPane(
        from sourcePaneId: PaneID,
        for movement: SurfacePaneMovement
    ) -> PaneID? {
        if let direction =
            dockDirectionalSplit(for: movement)?.direction {
            return bonsplitController.adjacentPane(
                to: sourcePaneId,
                direction: direction
            )
        }

        let orderedPaneIds = bonsplitController.treeSnapshot()
            .orderedPaneIds
            .compactMap(UUID.init(uuidString:))
        guard orderedPaneIds.count > 1,
              let sourceIndex = orderedPaneIds.firstIndex(
                  of: sourcePaneId.id
              ) else {
            return nil
        }
        let offset = movement == .previous ? -1 : 1
        let destinationIndex =
            (sourceIndex + offset + orderedPaneIds.count)
            % orderedPaneIds.count
        let destinationId = orderedPaneIds[destinationIndex]
        return bonsplitController.allPaneIds.first {
            $0.id == destinationId
        }
    }

    private func dockDirectionalSplit(
        for movement: SurfacePaneMovement
    ) -> (
        direction: NavigationDirection,
        orientation: SplitOrientation,
        insertFirst: Bool
    )? {
        switch movement {
        case .left:
            (.left, .horizontal, true)
        case .right:
            (.right, .horizontal, false)
        case .up:
            (.up, .vertical, true)
        case .down:
            (.down, .vertical, false)
        case .previous, .next:
            nil
        }
    }

    private func closeOtherDockTabsInFocusedPane() -> Bool {
        guard let paneId =
                bonsplitController.focusedPaneId
                ?? bonsplitController.allPaneIds.first else {
            return true
        }
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let selectedTabId =
                bonsplitController.selectedTab(inPane: paneId)?.id
                ?? tabs.first?.id else {
            return true
        }
        return closeDockTabs(
            tabs.lazy.filter { $0.id != selectedTabId }.map(\.id),
            inPane: paneId,
            confirmationPolicy: .allTabs
        )
    }

    private func startDockFind() -> Bool {
        if let terminal = focusedDockTerminalPanel {
            let hadExistingSearch = terminal.searchState != nil
            terminal.hostedView.preparePanelFocusIntentForActivation(
                .findField
            )
            let recoveredNeedle = hadExistingSearch
                ? ""
                : terminal.surface.lastSearchNeedle
            return startOrFocusTerminalSearch(
                terminal.surface,
                initialNeedle: recoveredNeedle
            ) { surface in
                NotificationCenter.default.post(
                    name: .ghosttySearchFocus,
                    object: surface,
                    userInfo: [
                        FindFocusNotificationKey.selectAll:
                            !hadExistingSearch
                            && !recoveredNeedle.isEmpty
                    ]
                )
            }
        }
        guard let browser = focusedDockBrowserPanel else {
            return false
        }
        browser.startFind()
        return browser.searchState != nil
    }

    private func performDockFindNavigation(
        _ navigation: TerminalSearchNavigation
    ) -> Bool {
        if let terminal = focusedDockTerminalPanel {
            return navigation.perform {
                terminal.performBindingAction($0)
            }
        }
        guard let browser = focusedDockBrowserPanel else {
            return false
        }
        switch navigation {
        case .next:
            browser.findNext()
        case .previous:
            browser.findPrevious()
        }
        return true
    }

    private func hideDockFind() -> Bool {
        if let terminal = focusedDockTerminalPanel {
            terminal.surface.closeSearchFromExplicitInput()
            return true
        }
        guard let browser = focusedDockBrowserPanel else {
            return false
        }
        browser.hideFind()
        return true
    }

    private func useDockSelectionForFind() -> Bool {
        guard let terminal = focusedDockTerminalPanel else {
            return false
        }
        if terminal.searchState == nil {
            terminal.searchState = TerminalSurface.SearchState()
        }
        NotificationCenter.default.post(
            name: .ghosttySearchFocus,
            object: terminal.surface
        )
        _ = terminal.performBindingAction("search_selection")
        return true
    }

    func toggleDockReactGrab(
        targeting explicitBrowserPanelId: UUID? = nil,
        returnTo explicitReturnTerminalPanelId: UUID? = nil
    ) -> Bool {
        let snapshots = panels.values.map {
            ReactGrabShortcutPanelSnapshot(
                id: $0.id,
                panelType: $0.panelType,
                isFocused: $0.id == focusedPanelId
            )
        }
        let route = resolveReactGrabShortcutRoute(panels: snapshots)
        let browserPanelId: UUID
        let returnTerminalPanelId: UUID?
        if let explicitBrowserPanelId {
            guard panels[explicitBrowserPanelId] is BrowserPanel else {
                return false
            }
            browserPanelId = explicitBrowserPanelId
            if let explicitReturnTerminalPanelId {
                guard panels[explicitReturnTerminalPanelId]
                    is TerminalPanel else {
                    return false
                }
                returnTerminalPanelId = explicitReturnTerminalPanelId
            } else {
                returnTerminalPanelId = nil
            }
        } else {
            guard explicitReturnTerminalPanelId == nil else {
                return false
            }
            guard let route else { return false }
            browserPanelId = route.browserPanelId
            returnTerminalPanelId = route.returnTerminalPanelId
        }
        guard let browser = panels[browserPanelId] as? BrowserPanel else {
            return false
        }

        if let returnTerminalPanelId {
            browser.armReactGrabRoundTrip(
                returnTo: returnTerminalPanelId
            )
        } else {
            browser.clearReactGrabRoundTrip(
                reason: "shortcut.noReturnTarget"
            )
        }
        if focusedPanelId != browser.id {
            if let zoomedPaneId = bonsplitController.zoomedPaneId {
                _ = toggleDockPaneZoom(inPane: zoomedPaneId)
            }
            focusPanelFromDockInteraction(browser.id, window: nil)
        }

        let didRequestExplicitWebViewFocus =
            browser.requestExplicitWebViewFocus()
        cancelDockReactGrabTask()
        let taskID = UUID()
        reactGrabTaskID = taskID
        reactGrabTaskPanelId = browser.id
        reactGrabTask = Task { @MainActor [weak self, weak browser] in
            defer {
                if self?.reactGrabTaskID == taskID {
                    self?.reactGrabTask = nil
                    self?.reactGrabTaskID = nil
                    self?.reactGrabTaskPanelId = nil
                }
            }
            guard !Task.isCancelled,
                  self?.reactGrabTaskID == taskID,
                  let browser else {
                return
            }
            if returnTerminalPanelId != nil {
                await browser.ensureReactGrabActive()
            } else {
                await browser.toggleOrInjectReactGrab()
            }
            guard !Task.isCancelled,
                  self?.reactGrabTaskID == taskID else {
                return
            }
            if !didRequestExplicitWebViewFocus {
                _ = browser.requestExplicitWebViewFocus()
            }
        }
        return true
    }

    /// Cancels pending Dock React Grab work when a newer command supersedes it
    /// or its owning browser is torn down.
    func cancelDockReactGrabTask(
        targetingPanelId panelId: UUID? = nil
    ) {
        if let panelId, reactGrabTaskPanelId != panelId {
            return
        }
        reactGrabTask?.cancel()
        reactGrabTask = nil
        reactGrabTaskID = nil
        reactGrabTaskPanelId = nil
    }
}

extension DockSplitStore: FocusHistoryHosting {
    var selectedWorkspaceId: UUID? { panels.isEmpty ? nil : workspaceId }

    func workspaceExists(_ workspaceId: UUID) -> Bool {
        self.workspaceId == workspaceId && !panels.isEmpty
    }

    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool {
        self.workspaceId == workspaceId && panels[panelId] != nil
    }

    func workspaceTitle(_ workspaceId: UUID) -> String? {
        self.workspaceId == workspaceId ? sourceLabel : nil
    }

    func panelTitle(workspaceId: UUID, panelId: UUID) -> String? {
        guard self.workspaceId == workspaceId else { return nil }
        return panels[panelId]?.displayTitle
    }

    func rememberedFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        self.workspaceId == workspaceId ? focusedPanelId : nil
    }

    func workspaceFocusedPanelId(_ workspaceId: UUID) -> UUID? {
        rememberedFocusedPanelId(workspaceId)
    }

    func firstPanelIdSortedByUUIDString(_ workspaceId: UUID) -> UUID? {
        guard self.workspaceId == workspaceId else { return nil }
        return panels.keys.min { $0.uuidString < $1.uuidString }
    }

    func selectWorkspace(_ workspaceId: UUID) {}

    func rememberFocusedSurface(workspaceId: UUID, surfaceId: UUID) {}

    func focusPanel(workspaceId: UUID, panelId: UUID) {
        guard self.workspaceId == workspaceId else { return }
        focusPanelFromDockInteraction(panelId, window: nil)
    }

    func triggerFocusFlash(workspaceId: UUID, panelId: UUID) {
        guard self.workspaceId == workspaceId else { return }
        triggerFocusFlash(panelId: panelId)
    }

    func focusSelectedWorkspacePanel() {
        guard let focusedPanelId else { return }
        focusPanelFromDockInteraction(focusedPanelId, window: nil)
    }

    func focusHistoryRevisionDidChange() {}
}
