import SwiftUI

/// Compact device controls presented from the sidebar's computer button.
/// Receives values and actions rather than holding an observable store.
struct DevicesSidebarControls: View {
    let discoveryEnabled: Bool
    let incomingAccessEnabled: Bool
    let discoveryManaged: Bool
    let incomingAccessManaged: Bool
    let setDiscovery: (Bool) -> Void
    let setIncomingAccess: (Bool) -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(localized: "settings.betaFeatures.devices", defaultValue: "My Devices"), systemImage: "desktopcomputer")
                .font(.headline)
            control(
                title: String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs"),
                detail: String(localized: "devices.discovery.menuDetail", defaultValue: "Connect to Macs signed in to your account."),
                enabled: discoveryEnabled, managed: discoveryManaged,
                identifier: "DevicesDiscoveryToggle", set: setDiscovery
            )
            control(
                title: String(localized: "devices.incoming.toggle", defaultValue: "Allow access to this Mac"),
                detail: String(localized: "devices.incoming.menuDetail", defaultValue: "Let your other Macs and iPhone connect here."),
                enabled: incomingAccessEnabled, managed: incomingAccessManaged,
                identifier: "DevicesIncomingAccessToggle", set: setIncomingAccess
            )
            Divider()
            Button(action: openSettings) {
                HStack {
                    Text(String(localized: "devices.settings", defaultValue: "Computers Settings…"))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func control(
        title: String, detail: String, enabled: Bool, managed: Bool,
        identifier: String, set: @escaping (Bool) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Toggle(title, isOn: Binding(get: { enabled && !managed }, set: set))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(managed)
                    .accessibilityIdentifier(identifier)
            }
            Text(managed
                ? String(localized: "devices.managed", defaultValue: "Disabled by your administrator.")
                : detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
