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

    var body: some View {
        switch style.machineRowLayout {
        case .singleLine:
            CloudTreeMachineBand(style: style) {
                HStack(alignment: .center, spacing: CloudTreeRowGrid.dotGap) {
                    leadingGlyph
                        .frame(width: CloudTreeRowGrid.dotSlot, alignment: .center)
                    HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.dotGap) {
                        name
                        status
                    }
                    Spacer(minLength: CloudTreeRowGrid.trailingGap)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(operation.summaryLine)
        case .twoLine:
            HStack(alignment: .top, spacing: CloudTreeRowGrid.dotGap) {
                leadingGlyph
                    .frame(width: CloudTreeRowGrid.dotSlot, height: style.machineNameLineHeight, alignment: .center)
                VStack(alignment: .leading, spacing: CloudTreeRowGrid.machineLineSpacing) {
                    name
                        .frame(height: style.machineNameLineHeight)
                    status
                        .frame(height: style.machineSubtitleLineHeight)
                }
                Spacer(minLength: CloudTreeRowGrid.trailingGap)
            }
            .padding(.vertical, style.machineVerticalPadding)
            .padding(.trailing, CloudTreeRowGrid.trailingPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(operation.summaryLine)
        }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if operation.isRunning {
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
        }
    }

    private var name: some View {
        Text(operation.request.displayName)
            .cmuxFont(size: style.machineNameSize, weight: style.machineBand ? .semibold : .medium, design: style.fontDesign)
            .foregroundStyle(operation.isRunning ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var status: some View {
        Text(operation.statusLabel)
            .cmuxFont(size: style.detailSize, design: style.fontDesign)
            .foregroundStyle(operation.isRunning ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange.opacity(0.9)))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
