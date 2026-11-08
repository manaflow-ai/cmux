import AppKit

extension AppDelegate {
    /// Routes the customizable browser-only shortcut without moving keyboard focus.
    func handleBrowserDesignModeShortcut(_ event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .toggleBrowserDesignMode) else {
            return nil
        }
        guard let panel = shortcutEventBrowserPanel(event) else { return false }
        Task { @MainActor in
            _ = await panel.toggleDesignMode(reason: "configuredShortcut")
        }
        return true
    }
}
