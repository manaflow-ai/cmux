import AppKit
import CmuxSettingsUI

/// Settings prefers a pane in the active workspace over a separate window
/// (https://github.com/manaflow-ai/cmux/pull/12302). The window remains the
/// fallback when no workspace can host a pane (no main window, tests).
extension SettingsWindowPresenter {
    /// Opens or focuses the Settings pane and delivers any pending navigation.
    /// Returns nil when there is no workspace to host it, so `show` falls
    /// back to the window path unchanged.
    func presentInWorkspacePane(activateApp: Bool) -> SettingsWindowShowResult? {
        guard let tabManager = AppDelegate.shared?.tabManager else { return nil }
        // A Settings pane already open anywhere wins: one Settings, one drafts owner.
        let hostingWorkspace = tabManager.tabs.first { $0.settingsPanel != nil } ?? tabManager.selectedWorkspace
        guard let workspace = hostingWorkspace else { return nil }
        let reused = workspace.settingsPanel != nil
        let target = pendingNavigationTarget
        let initialSection = target.flatMap { SettingsSectionID(rawValue: $0.rawValue) }
        guard let panel = workspace.openOrFocusSettingsSurface(initialSection: initialSection) else { return nil }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectedTabId = workspace.id
        }
        if reused, let target {
            // Mounted content: deliver now, like a reused window with ready content.
            pendingNavigationTarget = nil
            navigationDeliveryGeneration &+= 1
            SettingsNavigationRequest.post(target)
        }
        // A new pane keeps the target pending; its host root delivers it from onAppear.
        _ = panel
        if activateApp {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
        return .presented
    }
}
