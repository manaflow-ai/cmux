import CmuxSettings
import SwiftUI

/// The **App** section card for how updates install.
///
/// With Install Updates Automatically on, updates download in the background and install at a
/// quiet moment: no agent mid-turn, no running command, and no keyboard or mouse input for a
/// minute. Workspaces and agent sessions resume after the relaunch. The updater registers the
/// default per release channel (on for nightly), so the toggle shows that default until the
/// user changes it.
@MainActor
struct AppUpdatesCard: View {
    let hostActions: SettingsHostActions
    @State private var installAutomatically: DefaultsValueModel<Bool>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog, hostActions: SettingsHostActions) {
        self.hostActions = hostActions
        _installAutomatically = State(initialValue: DefaultsValueModel(
            store: defaultsStore,
            key: catalog.app.installUpdatesAutomatically
        ))
    }

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:app:install-updates-automatically",
                String(localized: "settings.app.installUpdatesAutomatically", defaultValue: "Install Updates Automatically"),
                subtitle: String(
                    localized: "settings.app.installUpdatesAutomatically.subtitle",
                    defaultValue: "Download updates in the background and install them when no agent is working and you step away for a minute. Workspaces and agents resume where they left off."
                )
            ) {
                Toggle("", isOn: Binding(
                    get: { installAutomatically.current },
                    set: { installAutomatically.set($0) { hostActions.installUpdatesAutomaticallyDidChange() } }
                ))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsInstallUpdatesAutomaticallyToggle")
            }
        }
        .task {
            startSettingsObservation([installAutomatically])
        }
    }
}
