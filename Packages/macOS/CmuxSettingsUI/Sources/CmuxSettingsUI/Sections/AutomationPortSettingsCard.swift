import SwiftUI

/// Settings card for the per-workspace automation port range.
@MainActor
struct AutomationPortSettingsCard: View {
    @Binding var portBase: Int
    @Binding var portRange: Int
    let controlWidth: CGFloat

    var body: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.portBase"),
                String(localized: "settings.automation.portBase", defaultValue: "Port Base"),
                subtitle: String(localized: "settings.automation.portBase.subtitle", defaultValue: "Starting port for CMUX_PORT env var."),
                controlWidth: controlWidth
            ) {
                TextField("", value: $portBase, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("automation.portRange"),
                String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"),
                subtitle: String(localized: "settings.automation.portRange.subtitle", defaultValue: "Number of ports per workspace."),
                controlWidth: controlWidth
            ) {
                TextField("", value: $portRange, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.port.note", defaultValue: "Each workspace gets CMUX_PORT and CMUX_PORT_END env vars with a dedicated port range. New terminals inherit these values."))
        }
    }
}
