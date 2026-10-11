import CmuxCloud
import CmuxFoundation
import CmuxSettingsUI
import SwiftUI

/// Persistent device controls receive a snapshot and the same setters as the menu.
struct CloudTreeDevicesEmptyView: View {
    let section: CloudTreeDevicesSection
    let actions: CloudTreeNodeActions
    let style: CloudTreeStyle
    var contentInset: CGFloat = 0
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification
    @State private var hoveredAction: String?

    /// The empty title sits this much closer to the My Devices header: its
    /// line is shorter and skips the inset above, since its smaller text
    /// otherwise reads as a gap under the header.
    static let emptyTitleLift: CGFloat = 4

    /// One row height per inline row, plus the 2 pt inset above and below,
    /// less the lift when the empty title leads.
    static func rowHeight(for section: CloudTreeDevicesSection, style: CloudTreeStyle) -> CGFloat {
        CGFloat(section.inlineRowCount) * style.rowHeight + 4 - (section.count == 0 ? emptyTitleLift : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if section.count == 0 {
                Text(String(localized: "cloudTree.devices.empty", defaultValue: "No devices yet"))
                    .cmuxFont(size: style.detailSize, design: style.fontDesign)
                    .foregroundStyle(.secondary)
                    .padding(.leading, scaled(textInset))
                    .padding(.trailing, scaled(style.rowGrid.trailingPadding))
                    .frame(height: scaled(style.rowHeight - (Self.emptyTitleLift - 2)))
            }
            actionRow(
                section.discoveryControl,
                symbol: "magnifyingglass",
                identifier: "DevicesEnableDiscovery"
            ) {
                actions.setDeviceDiscovery(!section.discoveryControl.isOn)
            }
            actionRow(
                section.incomingControl,
                symbol: "dot.radiowaves.left.and.right",
                identifier: "DevicesEnableIncomingAccess"
            ) {
                actions.setDeviceIncomingAccess(!section.incomingControl.isOn)
            }
        }
        .lineLimit(1)
        .padding(.top, scaled(section.count == 0 ? 0 : 2))
        .padding(.bottom, scaled(2))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func actionRow(
        _ control: DeviceAccessControl,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hoveredAction == identifier && control.isEnabled
        return Button(action: action) {
            CloudTreeLeafRow(
                style: style, icon: symbol, tint: .secondary,
                title: control.title, titleDimmed: !hovered
            ) {
                if control.isOn {
                    CmuxSystemSymbolImage(
                        magnified: "checkmark",
                        pointSize: style.detailSize,
                        tint: Color(nsColor: .labelColor)
                    )
                        .accessibilityHidden(true)
                }
            }
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
        .disabled(!control.isEnabled)
        .onHover { hoveredAction = $0 ? identifier : nil }
        .help(control.help)
        .accessibilityLabel(control.title)
        .accessibilityAddTraits(control.isOn ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }

    private var textInset: CGFloat {
        contentInset + (style.iconSlot > 0 ? style.iconSlot + style.iconGap : 0)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(value, percent: magnification)
    }
}
