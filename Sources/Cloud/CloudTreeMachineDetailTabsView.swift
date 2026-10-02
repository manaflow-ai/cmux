import CmuxCloud
import CmuxFoundation
import SwiftUI

/// One row of tabs under a Cloud machine's workspaces: Ports, Terminals and
/// Resources, each with its count. One tab is open at a time and its rows
/// show below; clicking the open tab closes it.
///
/// Compact tabs on the sidebar itself, with no track: each is as wide as its
/// label, takes the shared hover fill, and the open one is filled like a
/// selected row. The strip starts where its row's highlight would
/// (`CloudTreeHoverStyle`); the open tab's rows line up under the first tab
/// (`panelContentLeading`).
struct CloudTreeMachineDetailTabsView: View {
    let tabs: CloudTreeMachineDetailTabs
    let style: CloudTreeStyle
    /// Where the strip starts (`CloudTreeHoverStyle.leading`), already scaled.
    var leading: CGFloat = CloudTreeHoverStyle.horizontalInset
    let select: (CloudTreeMachineDetailTab) -> Void
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs.tabs, id: \.self) { tab in
                CloudTreeMachineDetailTabButton(
                    tab: tab,
                    count: tabs.count(for: tab),
                    isSelected: tabs.selected == tab,
                    style: style
                ) { select(tab) }
            }
        }
        .padding(.leading, leading)
        .padding(.trailing, CloudTreeHoverStyle.horizontalInset)
        .padding(.top, GlobalFontMagnification.scaledSize(Self.topGap, percent: magnification))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "cloudTree.machineDetails.label", defaultValue: "Machine Details"))
        .accessibilityIdentifier("CloudMachineDetailTabs")
    }

    /// Space between the Displays row and the tabs.
    static let topGap: CGFloat = 6

    /// Where an open tab's rows start their highlight: the first tab's edge.
    @MainActor
    static func panelHighlightLeading(tabRowLevel: Int, style: CloudTreeStyle) -> CGFloat {
        CloudTreeHoverStyle.leading(level: tabRowLevel, style: style)
    }

    /// Where an open tab's rows start their icon slot, so the glyph's visible
    /// edge lines up with the first tab's title. Icons sit centered in a wider
    /// slot, so the slot starts that inset earlier.
    @MainActor
    static func panelContentLeading(tabRowLevel: Int, style: CloudTreeStyle) -> CGFloat {
        let glyphInset = max(0, style.iconSlot - style.iconSize) / 2
        return panelHighlightLeading(tabRowLevel: tabRowLevel, style: style)
            + GlobalFontMagnification.scaledSize(CloudTreeMachineDetailTabButtonMetrics.horizontalPadding - glyphInset)
    }
}

/// One tab: its title and count. The open one is filled like a selected row;
/// the others take the shared hover fill.
private struct CloudTreeMachineDetailTabButton: View {
    let tab: CloudTreeMachineDetailTab
    let count: Int?
    let isSelected: Bool
    let style: CloudTreeStyle
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    private static let horizontalPadding = CloudTreeMachineDetailTabButtonMetrics.horizontalPadding
    private static let height = CloudTreeMachineDetailTabButtonMetrics.height

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(tab.title)
                    .cmuxFont(size: style.detailSize + 0.5, weight: isSelected ? .medium : .regular, design: style.fontDesign)
                    .foregroundStyle(isSelected || isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let count {
                    Text(count, format: .number)
                        .cmuxFont(size: style.detailSize - 0.5, design: style.fontDesign, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .frame(height: GlobalFontMagnification.scaledSize(Self.height, percent: magnification))
            .background(segment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? CloudTreeHoverStyle.fadeIn : CloudTreeHoverStyle.fadeOut), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: CloudTreeHoverStyle.fadeIn), value: isSelected)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(count.map { String($0) } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }

    private var segment: some View {
        RoundedRectangle(cornerRadius: CloudTreeHoverStyle.cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(
                isSelected ? CloudTreeHoverStyle.selectedOpacity : (isHovered ? CloudTreeHoverStyle.hoverOpacity : 0)
            ))
    }
}

/// Segment size, shared with the row height (`CloudTreeRowHeight`).
struct CloudTreeMachineDetailTabButtonMetrics {
    static let horizontalPadding: CGFloat = 8
    static let height: CGFloat = 20
}
