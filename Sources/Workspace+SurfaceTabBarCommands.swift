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


// MARK: - Surface tab bar command buttons
extension Workspace {
    private func selectedTerminalPanel(inPane pane: PaneID) -> TerminalPanel? {
        guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
              let panelId = panelIdFromSurfaceId(selectedTab.id) else {
            return nil
        }
        return terminalPanel(for: panelId)
    }

    private func executeSurfaceTabBarCommandButton(identifier: String, inPane pane: PaneID) {
        guard let executable = surfaceTabBarCommandButtons[identifier] else {
            return
        }
        let presentingWindow = selectedTerminalPanel(inPane: pane)?.surface.uiWindow
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow

        if let builtInAction = executable.builtInAction {
            switch builtInAction {
            case .newWorkspace:
                owningTabManager?.addWorkspace()
            case .cloudVM:
                _ = AppDelegate.shared?.performCloudVMAction(
                    tabManager: owningTabManager,
                    preferredWindow: presentingWindow,
                    debugSource: "surfaceTabBar.cloudVM"
                )
            case .newTerminal, .newBrowser, .splitRight, .splitDown:
                break
            }
            return
        }

        guard let globalConfigPath = surfaceTabBarButtonGlobalConfigPath else {
            return
        }

        if let workspaceCommand = executable.workspaceCommand {
            bonsplitController.focusPane(pane)
            if let selectedTab = bonsplitController.selectedTab(inPane: pane) {
                applyTabSelection(tabId: selectedTab.id, inPane: pane)
            }

            let paneDirectory = selectedTerminalPanel(inPane: pane).flatMap { terminal -> String? in
                for candidate in [panelDirectories[terminal.id], terminal.requestedWorkingDirectory] {
                    let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let trimmed, !trimmed.isEmpty {
                        return trimmed
                    }
                }
                return nil
            }
            let rawCwd = paneDirectory ?? currentDirectory
            let trimmedCwd = rawCwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseCwd = trimmedCwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : trimmedCwd
            guard let tabManager = owningTabManager else { return }
            _ = CmuxConfigExecutor.execute(
                command: workspaceCommand.command,
                tabManager: tabManager,
                baseCwd: baseCwd,
                configSourcePath: workspaceCommand.sourcePath,
                globalConfigPath: globalConfigPath,
                displayTitle: executable.button.title ?? executable.button.tooltip ?? workspaceCommand.command.name,
                actionID: executable.button.id,
                icon: executable.button.icon ?? executable.button.action.defaultButtonIcon,
                iconSourcePath: executable.button.iconSourcePath,
                presentingWindow: presentingWindow
            )
            return
        }

        guard let command = executable.button.terminalCommand else { return }
        let target = executable.button.resolvedTerminalCommandTarget
        let didExecute = CmuxConfigExecutor.prepareShellInputIfAuthorized(
            command,
            confirm: executable.button.confirm ?? false,
            actionID: executable.button.id,
            target: target,
            configSourcePath: executable.terminalCommandSourcePath ?? surfaceTabBarButtonSourcePath,
            globalConfigPath: globalConfigPath,
            displayTitle: executable.button.title ?? executable.button.tooltip,
            icon: executable.button.icon ?? executable.button.action.defaultButtonIcon,
            iconSourcePath: executable.button.iconSourcePath,
            presentingWindow: presentingWindow
        ) { [weak self] shellInput in
            guard let self else { return }
            self.bonsplitController.focusPane(pane)
            switch target {
            case .currentTerminal:
                self.selectedTerminalPanel(inPane: pane)?.sendInput(shellInput)
            case .newTabInCurrentPane:
                _ = self.newTerminalSurface(inPane: pane, focus: true, initialInput: shellInput)
            }
        }
        guard didExecute else {
            return
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        switch kind {
        case "terminal":
            _ = newTerminalSurface(inPane: pane)
        case "browser":
            _ = newBrowserSurface(inPane: pane)
        default:
            _ = newTerminalSurface(inPane: pane)
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestCustomAction identifier: String, inPane pane: PaneID) {
#if DEBUG
        cmuxDebugLog(
            "split.customAction.request workspace=\(id.uuidString.prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) identifier=\(identifier)"
        )
#endif
        executeSurfaceTabBarCommandButton(identifier: identifier, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        switch action {
        case .rename:
            promptRenamePanel(tabId: tab.id)
        case .clearName:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            setPanelCustomTitle(panelId: panelId, title: nil)
        case .copyIdentifiers:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            copyIdentifiersToPasteboard(surfaceId: panelId)
        case .closeToLeft:
            closeTabs(tabIdsToLeft(of: tab.id, inPane: pane))
        case .closeToRight:
            closeTabs(tabIdsToRight(of: tab.id, inPane: pane))
        case .closeOthers:
            closeTabs(tabIdsToCloseOthers(of: tab.id, inPane: pane))
        case .move:
            if let destination = bonsplitTabMoveDestinations(for: tab.id).first {
                _ = moveBonsplitTab(tab.id, toMoveDestination: destination.id)
            }
        case .moveToNewWorkspace:
            _ = AppDelegate.shared?.moveBonsplitTabToNewWorkspace(tabId: tab.id.uuid, focus: true, focusWindow: false)
        case .moveToLeftPane:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = moveSurfaceToAdjacentPane(panelId: panelId, direction: .left)
        case .moveToRightPane:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = moveSurfaceToAdjacentPane(panelId: panelId, direction: .right)
        case .newTerminalToRight:
            createTerminalToRight(of: tab.id, inPane: pane)
        case .newBrowserToRight:
            createBrowserToRight(of: tab.id, inPane: pane)
        case .reload:
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browser = browserPanel(for: panelId) else { return }
            browser.reload()
        case .toggleAudioMute:
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browser = browserPanel(for: panelId) else { return }
            guard browser.toggleMute() else {
                NSSound.beep()
                return
            }
            syncBrowserAudioMuteStateForPanel(panelId, browserPanel: browser)
        case .duplicate:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            _ = duplicateBrowserToRight(panelId: panelId)
        case .togglePin:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            let shouldPin = !pinnedPanelIds.contains(panelId)
            setPanelPinned(panelId: panelId, pinned: shouldPin)
        case .markAsRead:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            markPanelRead(panelId)
        case .markAsUnread:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            markPanelUnread(panelId)
        case .toggleZoom:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            toggleSplitZoom(panelId: panelId)
        case .forkConversation,
             .forkConversationRight,
             .forkConversationLeft,
             .forkConversationTop,
             .forkConversationBottom,
             .forkConversationNewTab,
             .forkConversationNewWorkspace:
            handleForkConversationContextAction(action, for: tab, inPane: pane)
        @unknown default:
            break
        }
    }

}
