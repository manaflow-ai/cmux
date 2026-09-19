import CmuxFoundation
import SwiftUI

/// This Mac's header row, on the same grid as the cloud machine row. Single- or
/// two-line per the style; no status dot (the local machine needs no link).
struct CloudTreeLocalMachineRowContent: View {
    let row: CloudTreeLocalMachineRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        switch style.machineRowLayout {
        case .singleLine:
            CloudTreeMachineBand(style: style) {
                HStack(alignment: .center, spacing: style.iconGap) {
                    CloudTreeRowIcon(style: style, systemName: "laptopcomputer", tint: CloudTreeIconPalette.machine)
                    Text(row.name)
                        .cmuxFont(size: style.machineNameSize, weight: style.machineBand ? .semibold : .medium, design: style.fontDesign)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: CloudTreeRowGrid.trailingGap)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.name)
        case .twoLine:
            HStack(alignment: .top, spacing: style.iconGap) {
                CloudTreeRowIcon(style: style, systemName: "laptopcomputer", tint: CloudTreeIconPalette.machine)
                    .frame(height: GlobalFontMagnification.scaledSize(style.machineNameLineHeight, percent: magnification))
                VStack(alignment: .leading, spacing: CloudTreeRowGrid.machineLineSpacing) {
                    Text(row.name)
                        .cmuxFont(size: style.machineNameSize, weight: .medium, design: style.fontDesign)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: style.machineNameLineHeight)
                    Text(Self.summary(row))
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
            .accessibilityLabel(row.name)
        }
    }

    /// "3 terminals · 1 browser"
    static func summary(_ row: CloudTreeLocalMachineRow) -> String {
        var parts = [CloudTreeRowContentView.count(row.terminalCount)]
        if row.browserCount > 0 {
            parts.append(
                row.browserCount == 1
                    ? String(localized: "cloudTree.local.browserCount.one", defaultValue: "1 browser")
                    : String(format: String(localized: "cloudTree.local.browserCount.other", defaultValue: "%d browsers"), row.browserCount)
            )
        }
        return parts.joined(separator: " · ")
    }
}

