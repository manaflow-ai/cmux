import SwiftUI

/// The empty section receives a snapshot and the same setters as its menu.
struct CloudTreeDevicesEmptyView: View {
    let section: CloudTreeDevicesSection
    let actions: CloudTreeNodeActions

    static func rowHeight(for section: CloudTreeDevicesSection) -> CGFloat {
        32 + (section.discoveryEnabled ? 0 : 38) + (section.incomingAccessEnabled ? 0 : 38)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "devices.empty.title", defaultValue: "No other Macs yet"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(height: 16)
            if !section.discoveryEnabled {
                Button {
                    actions.setDeviceDiscovery(true)
                } label: {
                    Text(String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs"))
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .disabled(section.discoveryManaged)
                .accessibilityIdentifier("DevicesEnableDiscovery")
            }
            if !section.incomingAccessEnabled {
                Button {
                    actions.setDeviceIncomingAccess(true)
                } label: {
                    Text(String(localized: "devices.incoming.toggle", defaultValue: "Make this Mac discoverable"))
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .disabled(section.incomingAccessManaged)
                .accessibilityIdentifier("DevicesEnableIncomingAccess")
            }
        }
        .font(.system(size: 11))
        .lineLimit(2)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.vertical, 8)
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
