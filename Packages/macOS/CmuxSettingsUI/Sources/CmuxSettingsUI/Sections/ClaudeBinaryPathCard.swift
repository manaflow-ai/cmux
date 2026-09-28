import CmuxFoundation
import SwiftUI

/// Settings card for the custom `claude` executable path.
@MainActor
struct ClaudeBinaryPathCard: View {
    let path: String
    let setPath: (String) -> Void

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.claudeBinaryPath"),
                String(localized: "settings.automation.claudeCode.customPath", defaultValue: "Claude Binary Path"),
                subtitle: String(localized: "settings.automation.claudeCode.customPath.subtitle", defaultValue: "Custom path to the claude binary. Leave empty to use PATH.")
            ) {
                TextField(
                    String(localized: "settings.automation.claudeCode.customPath.placeholder", defaultValue: "e.g. /usr/local/bin/claude"),
                    text: Binding(get: { path }, set: setPath)
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
    }
}
