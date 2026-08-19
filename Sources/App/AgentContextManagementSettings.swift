import Foundation
import CmuxSettings
import CmuxWorkspaces

/// UserDefaults-backed controls for terminal-side managed-agent context recovery.
struct AgentContextManagementSettings {
    static let didChangeNotification = Notification.Name("cmux.agentContextManagementSettingsDidChange")

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let catalog: TerminalCatalogSection

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        catalog: TerminalCatalogSection = TerminalCatalogSection()
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.catalog = catalog
    }

    var isEnabled: Bool {
        defaults.object(forKey: catalog.agentContextManagementEnabled.userDefaultsKey) as? Bool
            ?? catalog.agentContextManagementEnabled.defaultValue
    }

    var action: AgentContextInjectionAction {
        let rawValue = defaults.string(forKey: catalog.agentContextManagementAction.userDefaultsKey)
            ?? catalog.agentContextManagementAction.defaultValue
        return AgentContextInjectionAction(rawValue: rawValue) ?? .compact
    }

    var preservesState: Bool {
        defaults.object(forKey: catalog.agentContextManagementPreserveState.userDefaultsKey) as? Bool
            ?? catalog.agentContextManagementPreserveState.defaultValue
    }

    func notifyDidChange() {
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }
}
