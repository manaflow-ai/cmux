import CmuxSettings
import Foundation

/// Owns the persisted opt-in switch for the managed-agent stall supervisor.
struct AgentSessionAutoRetrySettings {
    static let autoRetryAgentSessionsKey = TerminalCatalogSection().autoRetryAgentSessions.userDefaultsKey
    static let defaultAutoRetryAgentSessions = TerminalCatalogSection().autoRetryAgentSessions.defaultValue
    static let didChangeNotification = Notification.Name("cmux.agentSessionAutoRetrySettingsDidChange")

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    var isEnabled: Bool {
        guard defaults.object(forKey: Self.autoRetryAgentSessionsKey) != nil else {
            return Self.defaultAutoRetryAgentSessions
        }
        return defaults.bool(forKey: Self.autoRetryAgentSessionsKey)
    }

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        defaults.set(enabled, forKey: Self.autoRetryAgentSessionsKey)
        if wasEnabled != enabled { notifyDidChange() }
    }

    @discardableResult
    func reset() -> Bool {
        let wasEnabled = isEnabled
        defaults.removeObject(forKey: Self.autoRetryAgentSessionsKey)
        let didChange = wasEnabled != isEnabled
        if didChange { notifyDidChange() }
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
            // NotificationCenter guarantees delivery on OperationQueue.main.
            MainActor.assumeIsolated { handler() }
        }
    }

    func removeDidChangeObserver(_ observer: NSObjectProtocol) {
        notificationCenter.removeObserver(observer)
    }
}
