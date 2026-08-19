import CmuxSettings
import Observation

/// Settings state for managed-agent recovery behavior.
@MainActor
@Observable
final class AgentRecoverySettingsModel: SettingObservationStarting {
    @ObservationIgnored private let hostActions: any SettingsHostActions
    private let autoRetry: DefaultsValueModel<Bool>

    init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: any SettingsHostActions
    ) {
        self.hostActions = hostActions
        self.autoRetry = DefaultsValueModel(
            store: defaultsStore,
            key: catalog.terminal.autoRetryAgentSessions
        )
    }

    var isAutoRetryEnabled: Bool { autoRetry.current }

    func startObserving() {
        autoRetry.startObserving()
    }

    func setAutoRetryEnabled(_ enabled: Bool) {
        autoRetry.set(enabled) { [hostActions] in
            hostActions.agentSessionAutoRetrySettingDidChange()
        }
    }
}
