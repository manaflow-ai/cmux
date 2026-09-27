import SwiftUI

/// The **App** section card that switches between the stable app and cmux NIGHTLY.
///
/// The two are separate apps that run side by side, so this is an action, not a setting:
/// the host opens the other app, installing it first when it is missing. Hidden when the
/// host offers no target (tagged development builds, previews).
@MainActor
struct AppChannelSwitchCard: View {
    let hostActions: SettingsHostActions

    var body: some View {
        if let target = hostActions.appChannelSwitchTarget() {
            SettingsCard {
                SettingsCardRow(
                    configurationReview: .action,
                    title(for: target),
                    subtitle: subtitle(for: target),
                    controlWidth: 196
                ) {
                    Button(buttonTitle(for: target)) {
                        hostActions.switchAppChannel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsAppChannelSwitchButton")
                }
            }
        }
    }

    private func title(for target: SettingsAppChannelSwitchTarget) -> String {
        switch target {
        case .nightly: String(localized: "settings.app.channelSwitch.nightly.title", defaultValue: "Nightly Build", bundle: .module)
        case .stable: String(localized: "settings.app.channelSwitch.stable.title", defaultValue: "Stable Release", bundle: .module)
        }
    }

    private func subtitle(for target: SettingsAppChannelSwitchTarget) -> String {
        switch target {
        case .nightly:
            String(
                localized: "settings.app.channelSwitch.nightly.subtitle",
                defaultValue: "Open cmux NIGHTLY, built daily from the latest code. It installs next to this app and updates separately.", bundle: .module
            )
        case .stable:
            String(
                localized: "settings.app.channelSwitch.stable.subtitle",
                defaultValue: "Open the stable cmux app. It installs next to this one if it is missing.", bundle: .module
            )
        }
    }

    private func buttonTitle(for target: SettingsAppChannelSwitchTarget) -> String {
        switch target {
        case .nightly: String(localized: "settings.app.channelSwitch.nightly.button", defaultValue: "Switch to Nightly", bundle: .module)
        case .stable: String(localized: "settings.app.channelSwitch.stable.button", defaultValue: "Switch to Stable", bundle: .module)
        }
    }
}
