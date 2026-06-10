import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Tab context menu actions
extension Workspace {
    func closeTabs(_ tabIds: [TabID], skipPinned: Bool = true) { closeTabsFromContextMenu(tabIds, skipPinned: skipPinned) }

    func tabIdsToLeft(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return [] }
        return Array(tabs.prefix(index).map(\.id))
    }

    func tabIdsToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }),
              index + 1 < tabs.count else { return [] }
        return Array(tabs.suffix(from: index + 1).map(\.id))
    }

    func tabIdsToCloseOthers(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        bonsplitController.tabs(inPane: paneId)
            .map(\.id)
            .filter { $0 != anchorTabId }
    }

    func createTerminalToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newTerminalSurface(inPane: paneId, focus: true) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    func createBrowserToRight(of anchorTabId: TabID, inPane paneId: PaneID, url: URL? = nil) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        let preferredProfileID = panelIdFromSurfaceId(anchorTabId).flatMap { browserPanel(for: $0)?.profileID }
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true,
            preferredProfileID: preferredProfileID
        ) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    @discardableResult
    func duplicateBrowserToRight(panelId: UUID, focus: Bool = true) -> BrowserPanel? {
        guard let anchorTabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId),
              let browser = browserPanel(for: panelId) else { return nil }
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: browser.currentURLForTabDuplication,
            focus: focus,
            preferredProfileID: browser.profileID,
            omnibarVisible: browser.isOmnibarVisible,
            bypassRemoteProxy: browser.bypassesRemoteWorkspaceProxyForTabDuplication
        ) else { return nil }
        newPanel.setMuted(browser.isMuted)
        syncBrowserAudioMuteStateForPanel(newPanel.id, browserPanel: newPanel)
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex, focus: focus)
        return newPanel
    }

    func promptRenamePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameTab.title", defaultValue: "Rename Tab")
        alert.informativeText = String(localized: "alert.renameTab.message", defaultValue: "Enter a custom name for this tab.")
        let currentTitle = panelCustomTitles[panelId] ?? panelTitles[panelId] ?? panel.displayTitle
        let input = NSTextField(string: currentTitle)
        input.placeholderString = String(localized: "alert.renameTab.placeholder", defaultValue: "Tab name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameTab.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        setPanelCustomTitle(panelId: panelId, title: input.stringValue)
    }

    private static let bonsplitMoveNewWorkspaceDestinationId = "new-workspace"
    private static let bonsplitMoveExistingWorkspacePrefix = "workspace:"

    func bonsplitTabMoveDestinations(for tabId: TabID) -> [TabContextMoveDestination] {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let app = AppDelegate.shared else { return [] }

        let workspaceTargets = app.workspaceMoveTargets(forBonsplitTab: tabId.uuid)
        var destinations: [TabContextMoveDestination] = []
        if app.canMoveSurfaceToNewWorkspace(panelId: panelId) {
            destinations.append(TabContextMoveDestination(
                id: Self.bonsplitMoveNewWorkspaceDestinationId,
                title: String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")
            ))
        }
        destinations.append(contentsOf: workspaceTargets.map { target in
            TabContextMoveDestination(
                id: Self.bonsplitMoveExistingWorkspacePrefix + target.workspaceId.uuidString,
                title: target.label
            )
        })
        return destinations
    }

    @discardableResult
    func moveBonsplitTab(_ tabId: TabID, toMoveDestination destinationId: String) -> Bool {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let app = AppDelegate.shared else { return false }

        let moved: Bool
        if destinationId == Self.bonsplitMoveNewWorkspaceDestinationId {
            moved = app.moveSurfaceToNewWorkspace(
                panelId: panelId,
                focus: true,
                focusWindow: false
            ) != nil
        } else if destinationId.hasPrefix(Self.bonsplitMoveExistingWorkspacePrefix) {
            let rawWorkspaceId = destinationId.dropFirst(Self.bonsplitMoveExistingWorkspacePrefix.count)
            guard let workspaceId = UUID(uuidString: String(rawWorkspaceId)) else { return false }
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
            )
        } else {
            moved = false
        }

        if !moved {
            showMoveTabFailureAlert()
        }
        return moved
    }

    private func showMoveTabFailureAlert() {
        let failure = NSAlert()
        failure.alertStyle = .warning
        failure.messageText = String(localized: "alert.moveTab.failed.title", defaultValue: "Move Failed")
        failure.informativeText = String(localized: "alert.moveTab.failed.message", defaultValue: "cmux could not move this tab to the selected destination.")
        failure.addButton(withTitle: String(localized: "alert.ok", defaultValue: "OK"))
        _ = failure.runModal()
    }

}
