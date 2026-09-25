import CmuxFoundation
import SwiftUI

/// Persistent device controls receive a snapshot and the same setters as the menu.
struct CloudTreeDevicesEmptyView: View {
    let section: CloudTreeDevicesSection
    let actions: CloudTreeNodeActions
    let style: CloudTreeStyle
    var contentInset: CGFloat = 0
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification
    @State private var hoveredAction: String?

    static func rowHeight(for section: CloudTreeDevicesSection, style: CloudTreeStyle) -> CGFloat {
        let rows = (section.count == 0 ? 1 : 0) + (section.discoveryEnabled ? 0 : 1) + (section.incomingAccessEnabled ? 0 : 1)
        return CGFloat(rows) * style.rowHeight + hintHeight(style: style) + 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if section.count == 0 {
                Text(String(localized: "devices.empty.title", defaultValue: "No other Macs yet"))
                    .cmuxFont(size: style.detailSize, design: style.fontDesign)
                    .foregroundStyle(.secondary)
                    .padding(.leading, scaled(textInset))
                    .padding(.trailing, scaled(style.rowGrid.trailingPadding))
                    .frame(height: scaled(style.rowHeight))
            }
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
            Text(menuHint)
                .cmuxFont(size: style.detailSize, design: style.fontDesign)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.leading, scaled(textInset))
                .padding(.trailing, scaled(style.rowGrid.trailingPadding))
                .frame(height: scaled(Self.hintHeight(style: style)))
                .padding(.top, scaled(4))
                .help(menuHint)
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
            .padding(.leading, scaled(contentInset))
            .frame(height: scaled(style.rowHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
                .padding(.horizontal, scaled(6))
        )
        .disabled(managed)
        .onHover { hoveredAction = $0 ? identifier : nil }
        .help(managed
            ? String(localized: "devices.managed", defaultValue: "Disabled by your administrator.")
            : title)
        .accessibilityIdentifier(identifier)
    }

    private var textInset: CGFloat {
        contentInset + (style.iconSlot > 0 ? style.iconSlot + style.iconGap : 0)
    }

    private var menuHint: String {
        String(localized: "devices.options.hint", defaultValue: "Change these options in the ⋯ menu next to My Devices.")
    }

    private static func hintHeight(style: CloudTreeStyle) -> CGFloat {
        2 * (style.detailSize + 3)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(value, percent: magnification)
    }
}
