import CmuxCloud
import CmuxFoundation
import SwiftUI

/// Another Mac's header row, on the same grid as This Mac's row and the cloud
/// machine rows: the desktop glyph in the leading slot, the name, a dim
/// instance tag for non-stable builds (a nightly or a dev tag; a stable Mac
/// shows none), and a dim status fact only when the Mac is not simply online.
/// Single- or two-line per the style, like ``CloudTreeLocalMachineRowContent``;
/// an offline Mac dims the way an exited terminal does.
struct CloudTreeDeviceRowContent: View {
    let row: CloudTreeDeviceRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current
    /// Injected so rows never read the wall clock in `body` on their own.
    var now: Date = Date()
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var fontMagnification

    var body: some View {
        CloudTreeMachineBand(style: style) {
            HStack(alignment: .top, spacing: scaled(style.iconGap)) {
                CloudTreeRowIcon(
                    style: style,
                    systemName: "desktopcomputer",
                    tint: CloudTreeIconPalette.machine,
                    dimmed: !row.isOnline
                )
                .frame(width: scaled(max(style.iconSlot, style.iconSize)), height: scaled(style.machineNameLineHeight))
                VStack(alignment: .leading, spacing: scaled(style.rowGrid.machineLineSpacing)) {
                    HStack(alignment: .firstTextBaseline, spacing: style.rowGrid.detailGap) {
                        name(weight: .medium)
                        tag
                        if style.machineRowLayout == .singleLine, let status = row.inlineStatus(now: now) {
                            statusText(status)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: scaled(style.machineNameLineHeight))
                    if style.machineRowLayout == .twoLine {
                        Text(Self.subtitle(row, now: now))
                            .cmuxFont(size: style.detailSize, design: style.fontDesign)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: scaled(style.machineSubtitleLineHeight))
                    }
                }
            }
            .padding(.vertical, scaled(style.machineVerticalPadding))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func scaled(_ size: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(size, percent: fontMagnification)
    }

    private func name(weight: Font.Weight) -> some View {
        Text(row.name)
            .cmuxFont(size: style.machineNameSize, weight: weight, design: style.fontDesign)
            .foregroundStyle(row.isOnline ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    @ViewBuilder
    private var tag: some View {
        if let tagLabel = row.tagLabel {
            Text(tagLabel)
                .cmuxFont(size: style.detailSize, design: style.fontDesign)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// The failure color a failed create uses; every other status stays tertiary.
    private func statusText(_ status: String) -> some View {
        Text(status)
            .cmuxFont(size: style.detailSize, design: style.fontDesign)
            .foregroundStyle(row.indicator == .attention ? AnyShapeStyle(Color.orange.opacity(0.9)) : AnyShapeStyle(.tertiary))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// "Studio, issue-8001, Online, 2 workspaces · 3 terminals" for assistive technology.
    var accessibilityLabel: String {
        var parts = [row.name]
        if let tagLabel = row.tagLabel { parts.append(tagLabel) }
        parts.append(row.statusLabel(now: now))
        let resources = Self.resourceSummary(row)
        if !resources.isEmpty { parts.append(resources) }
        return parts.joined(separator: ", ")
    }

    /// Name and tag over the full status and counts, for the row's tooltip:
    /// the inline fact truncates in a narrow sidebar and an online Mac shows none.
    var toolTip: String {
        var lines = [row.searchableTitle, row.statusLabel(now: now)]
        let resources = Self.resourceSummary(row)
        if !resources.isEmpty { lines.append(resources) }
        return lines.joined(separator: "\n")
    }

    /// The two-line layout's second line: status, then counts on an online Mac,
    /// the shape This Mac's summary line takes.
    static func subtitle(_ row: CloudTreeDeviceRow, now: Date) -> String {
        let resources = resourceSummary(row)
        guard !resources.isEmpty else { return row.statusLabel(now: now) }
        return [row.statusLabel(now: now), resources].joined(separator: " · ")
    }

    /// "2 workspaces · 3 terminals"; empty unless the Mac is online with something to open.
    static func resourceSummary(_ row: CloudTreeDeviceRow) -> String {
        guard row.isOnline else { return "" }
        var parts: [String] = []
        if row.workspaceCount > 0 {
            parts.append(
                String(localized: "cloudTree.device.workspaceCount.other", defaultValue: "\(row.workspaceCount) workspaces")
            )
        }
        if row.terminalCount > 0 {
            parts.append(CloudTreeRowContentView.count(row.terminalCount))
        }
        return parts.joined(separator: " · ")
    }
}
