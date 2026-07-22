import Bonsplit
import CmuxWorkspaces
import Foundation

enum DockShortcutCommand {
    case selectNextSurface
    case selectPreviousSurface
    case selectSurface(number: Int)
    case moveSurface(offset: Int)
    case focusPane(NavigationDirection)
    case togglePaneZoom
    case focusHistoryBack
    case focusHistoryForward
    case triggerFlash
}

extension DockSplitStore {
    /// Executes surface and focus commands against the Dock's own Bonsplit tree.
    /// AppDelegate resolves configured key bindings and sends only the semantic
    /// command here, keeping every Dock entrypoint on the same ownership path.
    @discardableResult
    func performShortcutCommand(_ command: DockShortcutCommand) -> Bool {
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
        case .focusPane(let direction):
            bonsplitController.navigateFocus(direction: direction)
            applyFocusedShortcutSelection()
            return true
        case .togglePaneZoom:
            guard let pane = bonsplitController.focusedPaneId else { return false }
            return toggleDockPaneZoom(inPane: pane)
        case .focusHistoryBack:
            return focusHistoryNavigation.navigateBack()
        case .focusHistoryForward:
            return focusHistoryNavigation.navigateForward()
        case .triggerFlash:
            guard let focusedPanelId else { return false }
            triggerFocusFlash(panelId: focusedPanelId)
            return true
        }
    }

    private func applyFocusedShortcutSelection() {
        guard let pane = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: pane) else { return }
        applyDockSelection(tabId: tab.id, inPane: pane)
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
        applyDockSelection(tabId: tab.id, inPane: pane)
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
        focusPanel(panelId)
    }

    func triggerFocusFlash(workspaceId: UUID, panelId: UUID) {
        guard self.workspaceId == workspaceId else { return }
        triggerFocusFlash(panelId: panelId)
    }

    func focusSelectedWorkspacePanel() {
        guard let focusedPanelId else { return }
        focusPanel(focusedPanelId)
    }

    func focusHistoryRevisionDidChange() {}
}
