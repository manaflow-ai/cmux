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

    var body: some View {
        switch style.machineRowLayout {
        case .singleLine:
            CloudTreeMachineBand(style: style) {
                HStack(alignment: .center, spacing: CloudTreeRowGrid.dotGap) {
                    glyph(size: max(style.iconSize, 9))
                        .frame(width: CloudTreeRowGrid.dotSlot, alignment: .center)
                    HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.detailGap) {
                        name(weight: style.machineBand ? .semibold : .medium)
                        tag
                        if let status = row.inlineStatus(now: now) {
                            statusText(status)
                        }
                    }
                    Spacer(minLength: CloudTreeRowGrid.trailingGap)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        case .twoLine:
            HStack(alignment: .top, spacing: CloudTreeRowGrid.dotGap) {
                glyph(size: 9)
                    .frame(width: CloudTreeRowGrid.dotSlot, height: style.machineNameLineHeight, alignment: .center)
                VStack(alignment: .leading, spacing: CloudTreeRowGrid.machineLineSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.detailGap) {
                        name(weight: .medium)
                        tag
                        Spacer(minLength: 0)
                    }
                    .frame(height: style.machineNameLineHeight)
                    Text(Self.subtitle(row, now: now))
                        .cmuxFont(size: style.detailSize + 0.5, design: style.fontDesign)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: style.machineSubtitleLineHeight)
                }
                Spacer(minLength: CloudTreeRowGrid.trailingGap)
            }
            .padding(.vertical, style.machineVerticalPadding)
            .padding(.trailing, CloudTreeRowGrid.trailingPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private func glyph(size: CGFloat) -> some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(glyphStyle)
            .accessibilityHidden(true)
    }

    private var glyphStyle: AnyShapeStyle {
        if !row.isOnline { return AnyShapeStyle(.tertiary) }
        return style.iconTreatment == .monochrome ? AnyShapeStyle(.secondary) : AnyShapeStyle(CloudTreeIconPalette.machine)
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
                row.workspaceCount == 1
                    ? String(localized: "cloudTree.device.workspaceCount.one", defaultValue: "1 workspace")
                    : String(format: String(localized: "cloudTree.device.workspaceCount.other", defaultValue: "%d workspaces"), row.workspaceCount)
            )
        }
        if row.terminalCount > 0 {
            parts.append(CloudTreeRowContentView.count(row.terminalCount))
        }
        return parts.joined(separator: " · ")
    }
}
