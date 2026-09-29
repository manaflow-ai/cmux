import SwiftUI

/// One of the two independent My Devices switches (discover other Macs, make
/// this Mac discoverable) as an inline Devices settings row. Mirrors
/// ``ComputerAccessMenuItems`` in the Cloud sidebar: a managed switch reads
/// off, cannot be flipped, and says why in its subtitle. While My Devices is
/// unavailable (Cloud Machines off or disabled by policy) the switch reads
/// off and cannot be flipped either; the section's note says why.
struct DevicesAccessToggleRow: View {
    let searchAnchorID: String
    let title: String
    let help: String
    let isOn: Bool
    let managed: Bool
    let unavailable: Bool
    let identifier: String
    let set: (Bool) -> Void

    var body: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: searchAnchorID,
            title,
            subtitle: managed ? String(localized: "devices.managed", defaultValue: "Disabled by your administrator.") : help
        ) {
            Toggle(title, isOn: Binding(get: { isOn && !managed && !unavailable }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(managed || unavailable)
                .accessibilityIdentifier(identifier)
        }
    }
}
