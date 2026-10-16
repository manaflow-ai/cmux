import AppKit
import CmuxCloud

/// Hooks other Cloud features register so the "What can I do here?" popover
/// and the tips can run them without owning them. A nil hook means the
/// feature is not available in this build, and its row or tip falls back.
@MainActor
final class CloudTeachingActionRegistry {
    static let shared = CloudTeachingActionRegistry()

    /// Opens the share flow for one forwarded port. Returns whether it started.
    var sharePort: (@MainActor (_ machineID: String, _ machineLabel: String, _ port: Int) -> Bool)?
}

/// The shared entrypoints behind the Cloud shortcuts that the palette, the
/// Cloud menus, the teaching popover and the hints all route through.
extension AppDelegate {
    /// Matches the Cloud teaching shortcuts: Toggle Cloud Sidebar, Cloud
    /// Secrets and Open Repository in Cloud.
    @MainActor
    func handleCloudTeachingShortcut(_ event: NSEvent) -> Bool {
        let window = event.window ?? shortcutRoutingActiveWindow
        if matchConfiguredShortcut(event: event, action: .toggleCloudPanel) {
            if !toggleCloudPanel(preferredWindow: window, debugSource: "shortcut.toggleCloudPanel") { NSSound.beep() }
            return true
        }
        if matchConfiguredShortcut(event: event, action: .openCloudSecrets) {
            if !openCloudSecrets(preferredWindow: window, debugSource: "shortcut.openCloudSecrets") { NSSound.beep() }
            return true
        }
        if matchConfiguredShortcut(event: event, action: .openRepositoryInCloud) {
            // Keep the shortcut transparent while signed out. The repository
            // action is unavailable in that state (the palette hides it), so
            // consuming a layout-translated key here would steal an unrelated
            // shortcut such as Close Other Tabs on Dvorak.
            guard CloudMachinesFeature.isEnabled, auth?.accountFlow.isAuthenticated == true else { return false }
            if !openRepositoryInCloud(preferredWindow: window, debugSource: "shortcut.openRepositoryInCloud") { NSSound.beep() }
            return true
        }
        return false
    }

    /// Shows the Cloud sidebar, or hides it when it is already showing Cloud.
    @MainActor
    @discardableResult
    func toggleCloudPanel(preferredWindow: NSWindow?, debugSource: String) -> Bool {
        guard CloudMachinesFeature.isEnabled, RightSidebarMode.machines.isAvailable(),
              let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
              let state = context.fileExplorerState else { return false }
#if DEBUG
        cmuxDebugLog("cloud.panel.toggle source=\(debugSource) visible=\(state.isVisible) mode=\(state.mode)")
#endif
        if state.isVisible, state.mode == .machines {
            state.setVisible(false)
            return true
        }
        return revealCloudMachinesSidebar(preferredWindow: context.window ?? preferredWindow)
    }

    /// Opens Cloud Secrets for every machine: the sheet the Cloud menu opens.
    @MainActor
    @discardableResult
    func openCloudSecrets(preferredWindow: NSWindow?, debugSource: String) -> Bool {
        guard CloudMachinesFeature.isEnabled, auth?.accountFlow.isAuthenticated == true else { return false }
#if DEBUG
        cmuxDebugLog("cloud.secrets.open source=\(debugSource)")
#endif
        CloudHintsCenter.shared.noteSecretsOpened()
        CloudSecretsSheetPresenter.shared.present(preferredWindow: preferredWindow)
        return true
    }

    /// Opens "Open Repository in Cloud…", the sheet the Cloud menu, palette
    /// and panel button open.
    @MainActor
    @discardableResult
    func openRepositoryInCloud(preferredWindow: NSWindow?, debugSource: String) -> Bool {
        guard CloudMachinesFeature.isEnabled, auth?.accountFlow.isAuthenticated == true else { return false }
        performOpenRepositoryInCloudAction(preferredWindow: preferredWindow, debugSource: debugSource)
        return true
    }

    /// Reveals the Cloud sidebar and opens its "What can I do here?" popover.
    @MainActor
    @discardableResult
    func showCloudTeachingHelp(preferredWindow: NSWindow?, debugSource: String) -> Bool {
        guard CloudMachinesFeature.isEnabled, RightSidebarMode.machines.isAvailable(),
              let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
              let state = context.fileExplorerState,
              revealCloudMachinesSidebar(preferredWindow: context.window ?? preferredWindow) else { return false }
#if DEBUG
        cmuxDebugLog("cloud.teaching.help.open source=\(debugSource)")
#endif
        state.cloudTeamPickerPresentation.isPresented = false
        state.cloudTeamPickerPresentation.isInvitePresented = false
        state.cloudTeamPickerPresentation.isHelpPresented = auth?.accountFlow.isAuthenticated == true
        return true
    }
}
