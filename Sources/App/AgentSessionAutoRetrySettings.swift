import CmuxSettings
import Foundation

struct AgentSessionAutoRetrySettings {
    static var autoRetryAgentSessionsKey: String {
        TerminalCatalogSection().autoRetryAgentSessions.userDefaultsKey
    }

    static var defaultAutoRetryAgentSessions: Bool {
        TerminalCatalogSection().autoRetryAgentSessions.defaultValue
    }
    static let didChangeNotification = Notification.Name("cmux.agentSessionAutoRetrySettingsDidChange")

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let key: DefaultsKey<Bool>

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        key: DefaultsKey<Bool> = TerminalCatalogSection().autoRetryAgentSessions
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.key = key
    }

    var isEnabled: Bool {
        guard defaults.object(forKey: key.userDefaultsKey) != nil else {
            return key.defaultValue
        }
        return defaults.bool(forKey: key.userDefaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        defaults.set(enabled, forKey: key.userDefaultsKey)
        if wasEnabled != enabled {
            notifyDidChange()
        }
    }

    @discardableResult
    func reset() -> Bool {
        let wasEnabled = isEnabled
        defaults.removeObject(forKey: key.userDefaultsKey)
        let didChange = wasEnabled != isEnabled
        if didChange {
            notifyDidChange()
        }
        return didChange
    }

    func notifyDidChange() {
        notificationCenter.post(name: Self.didChangeNotification, object: nil)
    }

    @MainActor
    func observeDidChange(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(
            forName: Self.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
    }

    func removeDidChangeObserver(_ observer: NSObjectProtocol) {
        notificationCenter.removeObserver(observer)
    }
}
