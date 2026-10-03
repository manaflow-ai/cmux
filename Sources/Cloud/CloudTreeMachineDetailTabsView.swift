import CmuxCloud
import CmuxFoundation
import SwiftUI

/// One row of tabs under a Cloud machine's workspaces: Ports, Terminals,
/// Displays and Resources, each with its count. One tab is open at a time and its rows
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
    @Namespace private var selectionNamespace
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The roomiest strip that fits wins, so a narrow sidebar tightens the
        // tabs, then drops their counts, before any title truncates. Nothing
        // is ever clipped: the last strip shrinks its titles instead.
        ViewThatFits(in: .horizontal) {
            strip(.regular)
            strip(.tight)
            strip(.titlesOnly)
            strip(.truncating)
        }
        .padding(.leading, leading)
        .padding(.trailing, CloudTreeHoverStyle.horizontalInset)
        .padding(.top, GlobalFontMagnification.scaledSize(Self.topGap, percent: magnification))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "cloudTree.machineDetails.label", defaultValue: "Machine Details"))
        .accessibilityIdentifier("CloudMachineDetailTabs")
    }

    @ViewBuilder
    private func strip(_ density: CloudTreeMachineDetailTabDensity) -> some View {
        let row = HStack(spacing: density.spacing) {
            ForEach(Array(tabs.tabs.enumerated()), id: \.element) { index, tab in
                CloudTreeMachineDetailTabButton(
                    tab: tab,
                    count: density.showsCounts ? tabs.count(for: tab) : nil,
                    isSelected: tabs.selected == tab,
                    style: style,
                    horizontalPadding: density.horizontalPadding,
                    selectionNamespace: selectionNamespace,
                    tabIndex: index
                ) { select(tab) }
            }
        }
        // A tighter tab starts later by what it saved, so the first title
        // stays on the column the open tab's rows line up with.
        .padding(.leading, GlobalFontMagnification.scaledSize(
            CloudTreeMachineDetailTabButtonMetrics.horizontalPadding - density.horizontalPadding,
            percent: magnification
        ))
        if density.truncates {
            row
        } else {
            row.fixedSize(horizontal: true, vertical: false)
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88),
            value: tabs.selected
        )
    }

    /// Space between the rows above and the tabs.
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
    var horizontalPadding = CloudTreeMachineDetailTabButtonMetrics.horizontalPadding
    let selectionNamespace: Namespace.ID
    let tabIndex: Int
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    private static let height = CloudTreeMachineDetailTabButtonMetrics.height

    var body: some View {
        Button(action: action) {
            // The smaller count sits on the title's baseline, not its middle.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
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
                        .contentTransition(.interpolate)
                }
            }
            .scaleEffect(isSelected ? 1 : 0.97, anchor: .leading)
            .padding(.horizontal, GlobalFontMagnification.scaledSize(horizontalPadding, percent: magnification))
            .frame(height: GlobalFontMagnification.scaledSize(Self.height, percent: magnification))
            .background(segment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: isHovered ? CloudTreeHoverStyle.fadeIn : CloudTreeHoverStyle.fadeOut), value: isHovered)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.28).delay(Double(tabIndex) * 0.035),
            value: isSelected
        )
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityValue(count.map { String($0) } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }

    private var segment: some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: CloudTreeHoverStyle.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(CloudTreeHoverStyle.selectedOpacity))
                    .matchedGeometryEffect(id: "machine-detail-tab-selection", in: selectionNamespace)
            } else if isHovered {
                RoundedRectangle(cornerRadius: CloudTreeHoverStyle.cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(CloudTreeHoverStyle.hoverOpacity))
            }
        }
    }
}

/// How much room each tab takes, from roomiest to tightest.
enum CloudTreeMachineDetailTabDensity: Equatable {
    case regular, tight, titlesOnly, truncating

    var horizontalPadding: CGFloat {
        self == .regular ? CloudTreeMachineDetailTabButtonMetrics.horizontalPadding : 4
    }

    var spacing: CGFloat { self == .regular ? 2 : 1 }

    var showsCounts: Bool { self == .regular || self == .tight }

    var truncates: Bool { self == .truncating }
}

/// Segment size, shared with the row height (`CloudTreeRowHeight`).
struct CloudTreeMachineDetailTabButtonMetrics {
    static let horizontalPadding: CGFloat = 8
    static let height: CGFloat = 20
}
