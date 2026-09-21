import CmuxFoundation
import SwiftUI

/// A machine that does not exist yet (or failed to): the row the Machines
/// panel shows from the moment the sheet's Create is pressed until the fleet
/// list returns the real machine. Mirrors ``CloudTreeMachineRowContent``'s
/// two layouts so the row sits in the same column grid as its neighbours;
/// the leading slot carries a spinner while running and a warning once
/// failed.
struct CloudTreePendingMachineRowContent: View {
    let operation: MachineCreateOperation
    var style: CloudTreeStyle = CloudTreeStyleStore.current
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        switch style.machineRowLayout {
        case .singleLine:
            CloudTreeMachineBand(style: style) {
                HStack(alignment: .center, spacing: scaled(style.iconGap)) {
                    leadingGlyph
                        .frame(width: scaled(style.iconSlot), alignment: .center)
                    HStack(alignment: .firstTextBaseline, spacing: style.rowGrid.dotGap) {
                        name
                        status
                    }
                    Spacer(minLength: style.rowGrid.trailingGap)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(operation.summaryLine)
        case .twoLine:
            HStack(alignment: .top, spacing: scaled(style.iconGap)) {
                leadingGlyph
                    .frame(width: scaled(style.iconSlot), height: scaled(style.machineNameLineHeight), alignment: .center)
                VStack(alignment: .leading, spacing: scaled(style.rowGrid.machineLineSpacing)) {
                    name
                        .frame(height: scaled(style.machineNameLineHeight))
                    status
                        .frame(height: scaled(style.machineSubtitleLineHeight))
                }
                Spacer(minLength: style.rowGrid.trailingGap)
            }
            .padding(.vertical, scaled(style.machineVerticalPadding))
            .padding(.trailing, style.rowGrid.trailingPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(operation.summaryLine)
        }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if operation.isRunning || operation.isReconciling {
            ProgressView()
                .controlSize(.mini)
        } else {
            CmuxSystemSymbolImage(
                magnified: "exclamationmark.triangle.fill",
                pointSize: style.iconSize,
                weight: .medium,
                tint: .orange
            )
        }
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(value, percent: magnification)
    }

    private var name: some View {
        Text(operation.request.displayName)
            .cmuxFont(size: style.machineNameSize, weight: style.machineBand ? .semibold : .medium, design: style.fontDesign)
            .foregroundStyle(operation.isRunning || operation.isReconciling ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var status: some View {
        Text(operation.statusLabel)
            .cmuxFont(size: style.detailSize, design: style.fontDesign)
            .foregroundStyle(operation.isRunning || operation.isReconciling ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange.opacity(0.9)))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
