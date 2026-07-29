import CmuxSettings
import Observation

/// Settings state and committed host side effects for agent recovery controls.
@MainActor
@Observable
final class AgentRecoverySettingsModel {
    let autoResume: DefaultsValueModel<Bool>
    let autoRetry: DefaultsValueModel<Bool>

    @ObservationIgnored private let hostActions: any SettingsHostActions

    init(
        defaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        hostActions: any SettingsHostActions
    ) {
        autoResume = DefaultsValueModel(
            store: defaultsStore,
            key: catalog.terminal.autoResumeAgentSessions
        )
        autoRetry = DefaultsValueModel(
            store: defaultsStore,
            key: catalog.terminal.autoRetryAgentSessions
        )
        self.hostActions = hostActions
    }

    func startObserving() {
        autoResume.startObserving()
        autoRetry.startObserving()
    }

    func setAutoResume(_ enabled: Bool) {
        autoResume.set(enabled)
    }

    func setAutoRetry(_ enabled: Bool) {
        autoRetry.set(enabled) { [hostActions] in
            hostActions.agentSessionAutoRetrySettingDidChange()
        }
    }
}
