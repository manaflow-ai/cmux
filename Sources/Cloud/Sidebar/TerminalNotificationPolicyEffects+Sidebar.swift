import CmuxSettings
import Foundation

extension TerminalNotificationPolicyEffects {
    /// Both sidebars receive exactly the same admitted ordering effect and live setting.
    @MainActor
    func applySidebarOrdering(defaults: UserDefaults, action: () -> Void) {
        guard reorderWorkspace,
              UserDefaultsSettingsClient(defaults: defaults).value(for: SettingCatalog().app.reorderOnNotification) else { return }
        action()
    }
}
