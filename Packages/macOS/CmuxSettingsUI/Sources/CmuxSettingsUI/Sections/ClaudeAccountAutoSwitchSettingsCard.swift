import CmuxFoundation
import CmuxSettings
import SwiftUI

/// Settings card for `automation.claudeAccountAutoSwitch`: when a Claude
/// account hits its usage limit, cmux continues the conversation on the next
/// account in `agents.claudeAccounts`. Off by default.
@MainActor
struct ClaudeAccountAutoSwitchSettingsCard: View {
    @State private var model: DefaultsValueModel<Bool>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _model = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.claudeAccountAutoSwitch))
    }

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.claudeAccountAutoSwitch"),
                String(
                    localized: "settings.automation.claudeAccountAutoSwitch",
                    defaultValue: "Switch Claude Account on Usage Limit",
                    bundle: .module
                ),
                subtitle: String(
                    localized: "settings.automation.claudeAccountAutoSwitch.subtitle",
                    defaultValue: "When a Claude account hits its usage limit, continue the conversation on the next account in agents.claudeAccounts.",
                    bundle: .module
                )
            ) {
                Toggle("", isOn: Binding(get: { model.current }, set: { model.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsClaudeAccountAutoSwitchToggle")
            }
        }
        .task {
            startSettingsObservation([model])
        }
    }
}
