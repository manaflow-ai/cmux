import CmuxFoundation
import SwiftUI

/// The empty section receives a snapshot and the same setters as its menu.
struct CloudTreeDevicesEmptyView: View {
    let section: CloudTreeDevicesSection
    let actions: CloudTreeNodeActions
    let style: CloudTreeStyle
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification
    @State private var hoveredAction: String?

    static func rowHeight(for section: CloudTreeDevicesSection, style: CloudTreeStyle) -> CGFloat {
        let rows = 1 + (section.discoveryEnabled ? 0 : 1) + (section.incomingAccessEnabled ? 0 : 1)
        return CGFloat(rows) * style.rowHeight + 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "devices.empty.title", defaultValue: "No other Macs yet"))
                .cmuxFont(size: style.detailSize, design: style.fontDesign)
                .foregroundStyle(.secondary)
                .padding(.leading, scaled(style.iconSlot > 0 ? style.iconSlot + style.iconGap : 0))
                .padding(.trailing, CloudTreeRowGrid.trailingPadding)
                .frame(height: scaled(style.rowHeight))
            if !section.discoveryEnabled {
                actionRow(
                    String(localized: "devices.discovery.toggle", defaultValue: "Discover other Macs"),
                    symbol: "magnifyingglass",
                    managed: section.discoveryManaged,
                    identifier: "DevicesEnableDiscovery"
                ) {
                    actions.setDeviceDiscovery(true)
                }
            }
            if !section.incomingAccessEnabled {
                actionRow(
                    String(localized: "devices.incoming.toggle", defaultValue: "Make this Mac discoverable"),
                    symbol: "dot.radiowaves.left.and.right",
                    managed: section.incomingAccessManaged,
                    identifier: "DevicesEnableIncomingAccess"
                ) {
                    actions.setDeviceIncomingAccess(true)
                }
            }
        }
        .lineLimit(1)
        .padding(.vertical, scaled(2))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func actionRow(
        _ title: String,
        symbol: String,
        managed: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hoveredAction == identifier && !managed
        return Button(action: action) {
            CloudTreeLeafRow(
                style: style, icon: symbol, tint: .secondary,
                title: title, titleDimmed: !hovered
            )
            .frame(height: scaled(style.rowHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .disabled(managed)
        .onHover { hoveredAction = $0 ? identifier : nil }
        .help(managed
            ? String(localized: "devices.managed", defaultValue: "Disabled by your administrator.")
            : title)
        .accessibilityIdentifier(identifier)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(value, percent: magnification)
    }
}
