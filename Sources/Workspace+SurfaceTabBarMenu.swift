import AppKit
import Bonsplit
import Foundation

extension Workspace {
    private func selectedTerminalPanel(inPane pane: PaneID) -> TerminalPanel? {
        guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
              let panelId = panelIdFromSurfaceId(selectedTab.id) else {
            return nil
        }
        return terminalPanel(for: panelId)
    }

    func executeSurfaceTabBarCommandButton(identifier: String, inPane pane: PaneID) {
        guard let executable = surfaceTabBarCommandButtons[identifier] else {
            return
        }
        executeSurfaceTabBarExecutableButton(executable, inPane: pane)
    }

    func executeSurfaceTabBarExecutableButton(_ executable: SurfaceTabBarExecutableButton, inPane pane: PaneID) {
        let presentingWindow = selectedTerminalPanel(inPane: pane)?.surface.uiWindow
            ?? NSApp.keyWindow
            ?? NSApp.mainWindow

        if !executable.menuItems.isEmpty {
            presentSurfaceTabBarMenu(executable, inPane: pane, presentingWindow: presentingWindow)
            return
        }

        if let builtInAction = executable.builtInAction {
            executeSurfaceTabBarBuiltInAction(builtInAction, inPane: pane, presentingWindow: presentingWindow)
            return
        }

        guard let globalConfigPath = surfaceTabBarButtonGlobalConfigPath else {
            return
        }

        let inlineWorkspaceCommand = executable.button.inlineWorkspaceSyntheticCommand
        if executable.workspaceCommand != nil || inlineWorkspaceCommand != nil {
            bonsplitController.focusPane(pane)
            if let selectedTab = bonsplitController.selectedTab(inPane: pane) {
                applyTabSelection(tabId: selectedTab.id, inPane: pane)
            }

            guard let tabManager = owningTabManager else { return }
            let command: CmuxCommandDefinition
            let configSourcePath: String?
            if let workspaceCommand = executable.workspaceCommand {
                command = workspaceCommand.command
                configSourcePath = workspaceCommand.sourcePath
            } else if let inlineWorkspaceCommand {
                command = inlineWorkspaceCommand
                configSourcePath = executable.button.actionSourcePath ?? surfaceTabBarButtonSourcePath
            } else {
                return
            }
            _ = CmuxConfigExecutor.execute(
                command: command,
                tabManager: tabManager,
                baseCwd: surfaceTabBarBaseCwd(inPane: pane),
                configSourcePath: configSourcePath,
                globalConfigPath: globalConfigPath,
                displayTitle: executable.button.title ?? executable.button.tooltip ?? command.name,
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
                _ = self.newTerminalSurface(
                    inPane: pane,
                    focus: true,
                    initialInput: shellInput,
                    inheritWorkingDirectoryFallback: true
                )
            }
        }
        guard didExecute else {
            return
        }
    }

    private func presentSurfaceTabBarMenu(
        _ executable: SurfaceTabBarExecutableButton,
        inPane pane: PaneID,
        presentingWindow: NSWindow?
    ) {
        let menu = NSMenu(title: surfaceTabBarMenuTitle(for: executable))
        let target = SurfaceTabBarMenuTarget(workspace: self, pane: pane)
        surfaceTabBarMenuTarget = target
        for item in executable.menuItems {
            appendSurfaceTabBarMenuItem(item, to: menu, target: target)
        }
        guard menu.items.isEmpty == false else {
            NSSound.beep()
            surfaceTabBarMenuTarget = nil
            return
        }

        if let event = NSApp.currentEvent,
           let view = event.window?.contentView {
            menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        } else if let view = presentingWindow?.contentView {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: view.bounds.maxX - 32, y: view.bounds.maxY - 24),
                in: view
            )
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        surfaceTabBarMenuTarget = nil
    }

    private func appendSurfaceTabBarMenuItem(
        _ executable: SurfaceTabBarExecutableButton,
        to menu: NSMenu,
        target: SurfaceTabBarMenuTarget
    ) {
        guard surfaceTabBarMenuItemIsVisible(executable, inPane: target.pane) else {
            return
        }

        let item = NSMenuItem(
            title: surfaceTabBarMenuTitle(for: executable),
            action: executable.menuItems.isEmpty ? #selector(SurfaceTabBarMenuTarget.performMenuItem(_:)) : nil,
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = SurfaceTabBarMenuItemPayload(item: executable)
        item.image = surfaceTabBarMenuImage(for: executable)
        item.isEnabled = surfaceTabBarMenuItemIsEnabled(executable, inPane: target.pane)
        if !executable.menuItems.isEmpty {
            let submenu = NSMenu(title: item.title)
            for child in executable.menuItems {
                appendSurfaceTabBarMenuItem(child, to: submenu, target: target)
            }
            item.submenu = submenu
            item.isEnabled = !submenu.items.isEmpty
        }
        menu.addItem(item)
    }

    private func surfaceTabBarMenuItemIsVisible(_ executable: SurfaceTabBarExecutableButton, inPane pane: PaneID) -> Bool {
        guard let builtInAction = executable.builtInAction else { return true }
        switch builtInAction {
        case .diffViewer:
            return surfaceTabBarPaneHasDisplayableDiff(inPane: pane)
        case .newWorkspace, .newAgentChat, .cloudVM, .mobileConnect, .newTerminal, .newBrowser,
             .newNote, .splitRight, .splitDown, .more, .rightSidebarFiles, .rightSidebarNotes,
             .rightSidebarFind, .rightSidebarVault, .rightSidebarFeed, .rightSidebarDock,
             .filesPane, .findPane, .vaultPane, .revealCurrentDirectoryInFinder,
             .customizeSurfaceTabBar:
            return true
        }
    }

    private func surfaceTabBarPaneHasDisplayableDiff(inPane pane: PaneID) -> Bool {
        guard owningTabManager != nil else { return false }
        // Mirror the owner chain openDiffViewerFromSurfaceTabBar targets: the
        // pane's selected surface, then the workspace repo (its cwd is the
        // execution fallback). Never other panes' repos — a dirty sibling in
        // another repo must not enable a Diff item that would open against
        // this pane's clean cwd.
        if let selectedTab = bonsplitController.selectedTab(inPane: pane),
           let panelId = panelIdFromSurfaceId(selectedTab.id),
           let isDirty = panelGitBranches[panelId]?.isDirty {
            return isDirty
        }
        return gitBranch?.isDirty ?? false
    }

    private func surfaceTabBarMenuTitle(for executable: SurfaceTabBarExecutableButton) -> String {
        if let builtInAction = executable.builtInAction {
            // Action references inherit the longer command title during config
            // resolution; the compact menu should only show explicit overrides.
            let defaultActionTitle = CmuxResolvedConfigAction.builtIn(builtInAction).title
            for candidate in [executable.button.title, executable.button.tooltip] {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty, trimmed != defaultActionTitle {
                    return trimmed
                }
            }
            return builtInAction.menuTitle
        }

        let button = executable.button
        for candidate in [button.title, button.tooltip] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        if let workspaceCommand = executable.workspaceCommand {
            return workspaceCommand.command.name
        }
        if let command = button.terminalCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return command
        }
        return button.id
    }

    private func surfaceTabBarMenuImage(for executable: SurfaceTabBarExecutableButton) -> NSImage? {
        let icon = executable.button.icon ?? executable.button.action.defaultButtonIcon
        guard case .symbol(let name) = icon else { return nil }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func surfaceTabBarMenuItemIsEnabled(_ executable: SurfaceTabBarExecutableButton, inPane pane: PaneID) -> Bool {
        guard let builtInAction = executable.builtInAction else { return true }
        guard builtInAction.isAvailable() else { return false }
        switch builtInAction {
        case .rightSidebarNotes:
            return RightSidebarMode.notes.isAvailable()
        case .rightSidebarFeed:
            return RightSidebarMode.feed.isAvailable()
        case .rightSidebarDock:
            return RightSidebarMode.dock.isAvailable()
        case .more:
            return !executable.menuItems.isEmpty
        case .filesPane, .findPane, .vaultPane:
            return !bonsplitController.allPaneIds.isEmpty
        case .diffViewer:
            return owningTabManager != nil
        case .newWorkspace, .newAgentChat, .cloudVM, .mobileConnect, .newTerminal, .newBrowser,
             .newNote, .splitRight, .splitDown,
             .rightSidebarFiles, .rightSidebarFind, .rightSidebarVault,
             .revealCurrentDirectoryInFinder, .customizeSurfaceTabBar:
            return true
        }
    }

    private func executeSurfaceTabBarBuiltInAction(
        _ action: CmuxSurfaceTabBarBuiltInAction,
        inPane pane: PaneID,
        presentingWindow: NSWindow?
    ) {
        switch action {
        case .newWorkspace:
            owningTabManager?.addWorkspace()
        case .newAgentChat:
            performSurfaceTabBarNewAgentChatAction(presentingWindow: presentingWindow)
        case .cloudVM:
            _ = AppDelegate.shared?.performCloudVMAction(
                tabManager: owningTabManager,
                preferredWindow: presentingWindow,
                debugSource: "surfaceTabBar.cloudVM"
            )
        case .mobileConnect:
            MobilePairingWindowController.shared.show()
        case .newTerminal:
            bonsplitController.focusPane(pane)
            _ = newTerminalSurface(inPane: pane, focus: true)
        case .newBrowser:
            bonsplitController.focusPane(pane)
            _ = newBrowserSurface(inPane: pane, focus: true)
        case .newNote:
            bonsplitController.focusPane(pane)
            let selectedPanelId = bonsplitController.selectedTab(inPane: pane)
                .flatMap { panelIdFromSurfaceId($0.id) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let selectedPanelId, panels[selectedPanelId] != nil {
                    _ = await openAttachedNoteForSurface(
                        inPane: pane,
                        panelId: selectedPanelId,
                        focus: true
                    )
                } else {
                    _ = await openAttachedNoteForWorkspace(inPane: pane, focus: true)
                }
            }
        case .splitRight:
            clearSplitZoom()
            _ = bonsplitController.splitPane(pane, orientation: .horizontal)
        case .splitDown:
            clearSplitZoom()
            _ = bonsplitController.splitPane(pane, orientation: .vertical)
        case .more:
            break
        case .rightSidebarFiles:
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .files,
                focusFirstItem: true,
                preferredWindow: presentingWindow
            )
        case .rightSidebarNotes:
            guard RightSidebarMode.notes.isAvailable() else {
                NSSound.beep()
                return
            }
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .notes,
                focusFirstItem: true,
                preferredWindow: presentingWindow
            )
        case .rightSidebarFind:
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .find,
                focusFirstItem: true,
                preferredWindow: presentingWindow
            )
        case .rightSidebarVault:
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .sessions,
                focusFirstItem: true,
                preferredWindow: presentingWindow
            )
        case .rightSidebarFeed:
            guard RightSidebarMode.feed.isAvailable() else {
                NSSound.beep()
                return
            }
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .feed,
                focusFirstItem: true,
                preferredWindow: presentingWindow
            )
        case .rightSidebarDock:
            guard RightSidebarMode.dock.isAvailable() else {
                NSSound.beep()
                return
            }
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: .dock,
                focusFirstItem: true,
                preferredWindow: presentingWindow
            )
        case .filesPane:
            openRightSidebarToolPane(.files, inPane: pane)
        case .findPane:
            openRightSidebarToolPane(.find, inPane: pane)
        case .vaultPane:
            openRightSidebarToolPane(.sessions, inPane: pane)
        case .diffViewer:
            openDiffViewerFromSurfaceTabBar(inPane: pane)
        case .revealCurrentDirectoryInFinder:
            let url = URL(fileURLWithPath: surfaceTabBarBaseCwd(inPane: pane), isDirectory: true)
            Task {
                await WorkspaceFinderDirectoryOpener.openInFinder(url)
            }
        case .customizeSurfaceTabBar:
            AppDelegate.shared?.openPreferencesWindow(
                debugSource: "surfaceTabBar.customize",
                navigationTarget: .paneTabBar
            )
        }
    }

    private func openRightSidebarToolPane(_ mode: RightSidebarMode, inPane pane: PaneID) {
        guard mode.canOpenAsPane else {
            NSSound.beep()
            return
        }
        clearSplitZoom()
        if openOrFocusRightSidebarToolSurface(inPane: pane, mode: mode, focus: true) == nil {
            NSSound.beep()
        }
    }

    private func openDiffViewerFromSurfaceTabBar(inPane pane: PaneID) {
        guard let selected = bonsplitController.selectedTab(inPane: pane) else {
            NSSound.beep()
            return
        }
        // Shared agent-aware opener, keyed to this pane's selected surface and
        // tracked cwd so the button targets its own pane, not global focus.
        let didOpen = AppDelegate.shared?.openDiffViewerFromSurfaceTabBar(
            for: owningTabManager,
            surfaceId: panelIdFromSurfaceId(selected.id),
            paneCwd: surfaceTabBarBaseCwd(inPane: pane)
        ) ?? false
        if !didOpen {
            NSSound.beep()
        }
    }

    private func surfaceTabBarBaseCwd(inPane pane: PaneID) -> String {
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
        return trimmedCwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : trimmedCwd
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        switch kind {
        case "terminal":
            _ = newTerminalSurface(inPane: pane, inheritWorkingDirectoryFallback: true)
        case "browser":
            _ = newBrowserSurface(inPane: pane)
        default:
            _ = newTerminalSurface(inPane: pane, inheritWorkingDirectoryFallback: true)
        }
    }
}
