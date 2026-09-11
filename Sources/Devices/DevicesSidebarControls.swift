import SwiftUI

/// Value-only controls outside the outline's observation boundary.
struct DevicesSidebarControls: View {
    let discoveryEnabled: Bool
    let incomingAccessEnabled: Bool
    let managed: Bool
    let setDiscovery: (Bool) -> Void
    let setIncomingAccess: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs"), isOn: Binding(
                get: { discoveryEnabled }, set: setDiscovery
            ))
            .accessibilityIdentifier("DevicesDiscoveryToggle")
            .help(String(localized: "devices.discovery.help", defaultValue: "Find and connect to other Macs signed in to your account. Turning this off disconnects their panes without closing their terminals."))
            Toggle(String(localized: "devices.incoming.toggle", defaultValue: "Allow access to this Mac"), isOn: Binding(
                get: { incomingAccessEnabled && !managed }, set: setIncomingAccess
            ))
            .accessibilityIdentifier("DevicesIncomingAccessToggle")
            .help(String(localized: "devices.incoming.help", defaultValue: "Make this Mac available to your other devices. Turning this off stops discovery and disconnects incoming Mac and iPhone sessions."))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 12))
        .disabled(managed)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
