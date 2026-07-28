import AppKit
import Bonsplit

extension cmuxApp {
    func performNewSimulatorPaneFromMenu() {
        guard let appDelegate = AppDelegate.shared,
              appDelegate.executeConfiguredCmuxAction(
                id: CmuxSurfaceTabBarBuiltInAction.newSimulator.configID,
                tabManager: activeTabManager,
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
              ) else {
            NSSound.beep()
            return
        }
    }
}

extension AppDelegate {
    func handleSimulatorShortcutRouting(_ event: NSEvent) -> Bool {
        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil {
            let focusContext = shortcutEventFocusContext(event)
            guard focusContext.simulatorFocused else { return handleSimulatorShortcut(event) }
            guard focusContext.allowsSimulatorShortcutRouting else { return false }
            let shortcutContext = focusContext.shortcutContext
            let chordActions = KeyboardShortcutSettings.Action.simulatorActions.filter { action in
                KeyboardShortcutSettings.effectiveWhenClause(for: action).evaluate(shortcutContext)
            }
            if armConfiguredShortcutChordIfNeeded(event: event, actions: chordActions) {
                return true
            }
        }
        return handleSimulatorShortcut(event)
    }

    func performConfiguredNewSimulatorAction(
        context: MainWindowContext,
        modelTarget: CmuxActionModelTarget?,
        focus: Bool,
        onExecuted: (() -> Void)?
    ) -> Bool {
        guard CmuxFeatureFlags.shared.isSimulatorEnabled else {
            return false
        }
        let workspace: Workspace
        let pane: PaneID
        if let modelTarget {
            guard let workspaceID = modelTarget.workspaceID,
                  let targetWorkspace = context.tabManager.tabs.first(
                    where: { $0.id == workspaceID }
                  ),
                  let panelID = modelTarget.panelID,
                  let targetPane = targetWorkspace.paneId(
                    forPanelId: panelID
                  ) else {
                return false
            }
            workspace = targetWorkspace
            pane = targetPane
        } else {
            guard let selectedWorkspace =
                    context.tabManager.selectedWorkspace,
                  let focusedPane =
                    selectedWorkspace.bonsplitController.focusedPaneId else {
                return false
            }
            workspace = selectedWorkspace
            pane = focusedPane
        }
        guard workspace.newSimulatorSurface(
            inPane: pane,
            focus: focus
        ) != nil else {
            return false
        }
        onExecuted?()
        return true
    }

    func isMenuBackedShortcutAction(_ action: KeyboardShortcutSettings.Action) -> Bool {
        action != .showHideAllWindows
            && action != .globalSearch
            && action != .clearScreenKeepScrollback
            && action != .fileExplorerOpenSelection
            && action != .fileExplorerOpenSelectionFinderAlias
            && !KeyboardShortcutSettings.Action.simulatorActions.contains(action)
    }
}
