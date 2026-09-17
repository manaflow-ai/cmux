import CmuxSettings
import SwiftUI

/// The updates card in the **App** section: the `updates.channel` picker plus its caption.
///
/// Bound through `@LiveSetting`, so the card resolves the JSON store from the environment
/// and ``AppSection`` needs no extra store plumbing. Persisting the pick writes cmux.json;
/// the app's update-channel bridge observes that write and triggers an update check.
@MainActor
struct UpdateChannelCard: View {
    @LiveSetting(\.updates.channel) private var channel

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("updates.channel"),
                String(localized: "settings.updates.channel", defaultValue: "Update channel")
            ) {
                Picker("", selection: $channel) {
                    ForEach(UpdateChannel.allCases, id: \.self) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsUpdateChannelPicker")
            }
            SettingsCardDivider()
            SettingsCardNote(
                String(
                    localized: "settings.updates.channel.caption",
                    defaultValue: "Release candidates are the next stable build, published a few days early. Switching back to Stable stops release-candidate updates but does not downgrade."
                )
            )
        }
    }
}
