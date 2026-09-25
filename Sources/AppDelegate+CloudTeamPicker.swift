import CmuxCloud
import AppKit

extension AppDelegate {
    @MainActor
    func handleCloudTeamPickerShortcut(_ event: NSEvent) -> Bool {
        guard matchConfiguredShortcut(event: event, action: .openTeamPicker) else { return false }
        _ = openCloudTeamPicker(
            preferredWindow: event.window ?? shortcutRoutingActiveWindow,
            debugSource: "shortcut.openTeamPicker"
        )
        return true
    }

    /// Reveals the active window's Cloud panel and requests its team menu.
    @MainActor
    @discardableResult
    func openCloudTeamPicker(
        preferredWindow: NSWindow? = nil,
        debugSource: String
    ) -> Bool {
        guard CloudMachinesFeature.isEnabled,
              RightSidebarMode.machines.isAvailable() else {
            let alert = NSAlert()
            alert.messageText = String(localized: "command.auth.teamPicker.title", defaultValue: "Open Team Picker")
            alert.informativeText = CloudMachinesFeature.disabledMessage
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            if let window = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return false
        }

        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
              let state = context.fileExplorerState else {
            NSSound.beep()
            return false
        }

        state.mode = .machines
        state.setVisible(true)
        _ = focusRightSidebarInActiveMainWindow(
            mode: .machines,
            focusFirstItem: false,
            preferredWindow: context.window ?? preferredWindow
        )
        state.cloudTeamPickerPresentation.isPresented = auth?.accountFlow.isAuthenticated == true
#if DEBUG
        cmuxDebugLog("cloud.teamPicker.open source=\(debugSource)")
#endif
        return true
    }
}
