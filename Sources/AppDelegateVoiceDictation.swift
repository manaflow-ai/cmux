import AppKit
import Bonsplit

// Composition and focus resolution for voice dictation. The runtime is owned
// by the SwiftUI composition root; this extension keeps focus resolution out
// of the AppDelegate god file.
extension AppDelegate {
    /// Toggles dictation from a button or the command palette.
    ///
    /// - Returns: `false` when dictation is disabled in Settings.
    @discardableResult
    func toggleVoiceDictationFromUI() -> Bool {
        voiceDictationRuntime?.toggleFromUI() ?? false
    }

    /// Toggles dictation into a target resolved by the clicked UI control.
    @discardableResult
    func toggleVoiceDictationFromUI(target: VoiceDictationTerminalTarget) -> Bool {
        voiceDictationRuntime?.toggleFromUI(target: target) ?? false
    }

    /// Resolves the focused terminal for the key window, mirroring the
    /// multi-window resolution used by other text-insertion features, and
    /// whether a coding agent is running in it.
    ///
    /// Fails closed when a non-main window (Settings, a detached panel) is key,
    /// or when no key window exists, rather than typing into a terminal the
    /// user is not looking at.
    func voiceDictationFocusedTerminalTarget() -> VoiceDictationTerminalTarget? {
        guard let window = NSApp.keyWindow else { return nil }

        // The focus controller is authoritative even while AppKit's first
        // responder is still a stale main-terminal view (a common transition
        // state when the right sidebar is being mounted). Resolve the Dock's
        // selected terminal when it owns focus and reject every other sidebar
        // mode so text can never land in an invisible main PTY.
        guard let context = contextForMainTerminalWindow(window) else {
            return nil
        }
        switch context.keyboardFocusCoordinator.activeRightSidebarMode {
        case .dock:
            guard let dock = existingWindowDock(forWindowId: context.windowId),
                  let panelId = dock.focusedPanelId,
                  dock.isVisibleInUI,
                  dock.panelIsActiveInVisibleDockPane(panelId),
                  let panel = dock.panels[panelId] as? TerminalPanel else {
                return nil
            }
            // Dock terminals belong to no workspace, so only their launch
            // command can say whether an agent runs there.
            return VoiceDictationTerminalTarget(panel: panel, isAgentPrompt: false)
        case .some:
            return nil
        case nil:
            guard let workspace = context.tabManager.selectedWorkspace,
                  let panel = workspace.focusedTerminalInputTarget()?.panel else {
                return nil
            }
            let agentContext = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
            return VoiceDictationTerminalTarget(
                panel: panel,
                isAgentPrompt: TextBoxAgentDetection.supportsActiveAgentPrefixes(context: agentContext)
            )
        }
    }
}

extension AppDelegate {
    /// Rebuilds every workspace's surface tab bar after the mic button's
    /// visibility setting changes.
    func reapplyVoiceDictationTabBarButtons() {
        for workspace in allTabManagersForManagedPolicyEnforcement().flatMap(\.tabs) {
            workspace.reapplySurfaceTabBarButtonsForFeatureFlags()
        }
    }
}

extension Workspace {
    func voiceDictationTerminalTarget(inPane pane: PaneID) -> VoiceDictationTerminalTarget? {
        guard let (_, panel) = controlDefaultTerminalTarget(paneID: pane.id) else { return nil }
        let agentContext = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: self)
        return VoiceDictationTerminalTarget(
            panel: panel,
            isAgentPrompt: TextBoxAgentDetection.supportsActiveAgentPrefixes(context: agentContext)
        )
    }

    /// The surface tab bar's mic button: focus the pane it was clicked in,
    /// then toggle dictation into that pane.
    func toggleVoiceDictationFromTabBar(inPane pane: PaneID) {
        bonsplitController.focusPane(pane)
        if let selectedTab = bonsplitController.selectedTab(inPane: pane) {
            applyTabSelection(tabId: selectedTab.id, inPane: pane)
        }
        guard let target = voiceDictationTerminalTarget(inPane: pane),
              AppDelegate.shared?.toggleVoiceDictationFromUI(target: target) == true else {
            NSSound.beep()
        }
    }
}

extension AppDelegate {
    /// `cmux.voiceDictation` from a configured action (tab bar, plus menu,
    /// palette): the same toggle as the mic button.
    func performConfiguredVoiceDictationAction(onExecuted: (() -> Void)?) -> Bool {
        guard toggleVoiceDictationFromUI() else { return false }
        onExecuted?()
        return true
    }
}
